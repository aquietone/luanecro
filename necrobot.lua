--[[
    NecroBot 1.0 - Automate your necro

    TODO:
    - track active targets? resist checks / immunities sort of things, maybe support for dotting multiple mobs
    - probably update debuff logic from the simple 2 mob table it has now
    - lifetapping? agro mgmt? other things automation macros do? ignore lists? rezzing?
    - better ui layout?

    Available modes:
    - Manual: choose your own targets to engage and let the script do the rest
    - Assist: set a camp at your current location and assist the MA on targets within your camp
    - Chase:  follow somebody around and assist the MA

    Spell Sets:
    - standard: Raid spell lineup including swapping out spells
    - short:    Group spell lineup with swarm pets and no swapping out spells

    Commands:
    - /nec prep:       pre-pop some burns incase you're sitting in the GH waiting for an event to start
    - /nec burnnow:    activate full burns immediately
    - /nec mode 0|1|2: set your mode. 0=manual, 1=assist, 2=chase
    - /nec show|hide:  toggle the UI window
    - /nec resetcamp:  reset camp location to current position

    Other Settings:
    - Assist:         Select the main assist from one of group, raid1, raid2, raid3
    - Assist Percent: Target percent HP to assist the MA.
    - Camp Radius:    Only assist on targets within this radius of you, whether camp is set or chasing.
    - Chase Target:   Name of the PC to chase.
    - Burn Percent:   Target percent HP to engage burns. This applies to burn named and burn on proliferation proc. 0 ignores the percent check.
    - Burn Count:     Start burns if greater than or equal to this number of mobs in camp.
    - Stop Percent:   Target Percent HP to stop casting DoTs.

    - Burn Always:    Engage burns as they are available.
    - Burn Named:     Engage burns on named mobs.
    - Burn on Proc:   Engage burns when proliferation procs from wounds dot.
    - Debuff:         Attempt to debuff targets.
    - Alliance:       Use alliance if more than 1 necro in group or raid.
    - Mana Tap:       Use mana drain. Replaces ignite DoT
    - Switch with MA: Always change to the MAs current target.

    - Summon Pet:     Toggle summoning of pet, will be done out of combat if pet is dead.
    - Buff Pet:       Toggle casting sigil on pet, will be done out of combat if missing.
    - Buff Shield:    Toggle casting shield of inevitability. Only casts in standard spell set, will be kept up at all times. Replaces corruption DoT.
    - Feign Death:    Toggle using FD AA's to reduce aggro.
    - Use Rez:        Toggle use of convergence AA to rez group members.

    What all necro bot does:
    1. Keeps you in your camp if assist mode is set
    2. Keeps up with your chase target if chase mode is set
    3. Assist MA if assist conditions are met (mob in range, at or below assist %, target switching on or not currently engaged)
    4. Send pet
    5. Cast scent debuff if debuffing is on
    6. Find the next best DPS spell to cast
        - Standard spell set:
        1. Synergy nuke if at least 3 DoTs are already applied to the target.
        2. Alliance if enabled and enough necros are available, and at least 3 DoTs are already applied to the target.
        3. DoTs from the "dots.standard" table in priority order
        - Short spell set:
        1. Synergy nuke if at least 3 DoTs are already applied to the target.
        2. Alliance if enabled and enough necros are available, and at least 3 DoTs are already applied to the target.
        3. DoTs from the "dots.short" table in priority order
        4. Call swarm
    7. Swap gems if swap conditions met
    8. Engage burns if burn conditions met
    9. Use mana recovery stuff if low mana
    10. Buffs if needed and out of combat. (shield, unity, pet haste)
    11. Summon pet if its dead and out of combat.
    12. Sit if low mana and not in combat

    Spells can be adjusted:
    - See "spells" table for full list of spells this script cares about.
    - See "dots" table for priority order of dots to cast.
    - See "items" table for clicky items used during burns
    - See "AAs" table for AAs used during burns
    - See "pre_burn_items" table for items used during prepare burns.
    - See "pre_burn_AAs" table for AAs used during prepare burns.

    Spell bar ordering can be adjusted by rearranging things in the "check_spell_set" function.

    Spell Swapping:
    The standard spell rotation expects only one of "Infected Wounds", "Scalding Shadow" or "Pyre of the Neglected" to be memmed at any given time.
    The standard spell rotation expects only one of "Fleshrot's Decay" or "Grip of Quietus" to be memmed at any given time.

    Other things to note:
    - Drops target and backs off pet if MA targets themself.
    - Does not break invis in any mode.

    Burn Conditions:
    - Burn Always:  Use burns as they are available. Attempt at least some synergy for twincast -- only twincast if spire and hand of death are ready
    - Burn Named:   Burn on anything with Target.Named == true
    - Burn Proc:    Burn on anything once proliferation DoT is up
    - Burn Count:   Burn once X # of mobs are in camp
    - Burn Pct:     Burn anything below a certain % HP

    Settings are stored in config/necrobot_server_charactername.lua

--]]


--- @type mq
local mq = require('mq')
--- @type ImGui
require 'ImGui'

local MODES = {'manual','assist','chase'}
local SPELLSETS = {standard=1,short=1}
local ASSISTS = {group=1,raid1=1,raid2=1,raid3=1}
local OPTS = {
    MODE='manual',
    CHASETARGET='',
    CHASEDISTANCE=30,
    CAMPRADIUS=60,
    ASSIST='group',
    AUTOASSISTAT=98,
    SPELLSET='standard',
    BURNALWAYS=false, -- burn as burns become available
    BURNPCT=0, -- delay burn until mob below Pct HP, 0 ignores %.
    BURNPROC=false, -- enable automatic burn when wounds procs, pass noburn arg to disable
    BURNALLNAMED=false, -- enable automatic burn on named mobs
    BURNCOUNT=5, -- number of mobs to trigger burns
    STOPPCT=0,
    DEBUFF=true, -- enable use of debuffs
    USEALLIANCE=false, -- enable use of USEALLIANCE spell
    USEBUFFSHIELD=false,
    SWITCHWITHMA=true,
    SUMMONPET=false,
    BUFFPET=true,
    USEMANATAP=false,
    USEREZ=true,
    USEFD=true,
    USEINSPIRE=true,
    BYOS=false,
    USEWOUNDS=true,
    MULTIDOT=false,
    MULTICOUNT=3,
    USEGLYPH=false,
    USEINTENSITY=false,
}
local DEBUG=false
local PAUSED=true -- controls the main combat loop
local BURN_NOW = false -- toggled by /burnnow binding to burn immediately
local CAMP = nil
local SPELLSET_LOADED = nil
local I_AM_DEAD = false

local DOT_TARGETS = {}

local LOG_PREFIX = '\a-t[\ax\ayNecroBot\ax\a-t]\ax '
local function printf(...)
    print(LOG_PREFIX..string.format(...))
end
local function debug(...)
    if DEBUG then printf(...) end
end

local function get_spellid_and_rank(spell_name)
    local spell_rank = mq.TLO.Spell(spell_name).RankName()
    return {['id']=mq.TLO.Spell(spell_rank).ID(), ['name']=spell_rank}
end

-- All spells ID + Rank name
local spells = {
    ['wounds']=get_spellid_and_rank('Infected Wounds'),
    ['fireshadow']=get_spellid_and_rank('Scalding Shadow'),
    ['combodis']=get_spellid_and_rank('Danvid\'s Grip of Decay'),
    ['pyreshort']=get_spellid_and_rank('Pyre of Va Xakra'),
    ['pyrelong']=get_spellid_and_rank('Pyre of the Neglected'),
    ['venom']=get_spellid_and_rank('Hemorrhagic Venom'),
    ['magic']=get_spellid_and_rank('Extinction'),
    ['haze']=get_spellid_and_rank('Zelnithak\'s Pallid Haze'),
    ['grasp']=get_spellid_and_rank('The Protector\'s Grasp'),
    ['leech']=get_spellid_and_rank('Twilight Leech'),
    ['ignite']=get_spellid_and_rank('Ignite Cognition'),
    ['scourge']=get_spellid_and_rank('Scourge of Destiny'),
    ['corruption']=get_spellid_and_rank('Decomposition'),
    ['alliance']=get_spellid_and_rank('Malevolent Coalition'),
    ['synergy']=get_spellid_and_rank('Proclamation for Blood'),
    ['composite']=get_spellid_and_rank('Composite Paroxysm'),
    ['decay']=get_spellid_and_rank('Fleshrot\'s Decay'),
    ['grip']=get_spellid_and_rank('Grip of Quietus'),
    ['proliferation']=get_spellid_and_rank('Infected Proliferation'),
    ['scentterris']=get_spellid_and_rank('Scent of Terris'),
    ['scentmortality']=get_spellid_and_rank('Scent of The Grave'),
    ['swarm']=get_spellid_and_rank('Call Skeleton Mass'),
    ['venin']=get_spellid_and_rank('Embalming Venin'),
    ['lich']=get_spellid_and_rank('Lunaside'),
    ['flesh']=get_spellid_and_rank('Flesh to Venom'),
    ['pet']=get_spellid_and_rank('Unrelenting Assassin'),
    ['pethaste']=get_spellid_and_rank('Sigil of Undeath'),
    ['shield']=get_spellid_and_rank('Shield of Inevitability'),
    ['manatap']=get_spellid_and_rank('Mind Atrophy'),
    ['petillusion']=get_spellid_and_rank('Form of Mottled Bone'),
    ['inspire']=get_spellid_and_rank('Inspire Ally'),
}
for _,spell in pairs(spells) do
    printf('%s (%s)', spell['name'], spell['id'])
end

-- entries in the dots table are pairs of {spell id, spell name} in priority order
local standard = {}
table.insert(standard, spells['wounds'])
table.insert(standard, spells['composite'])
table.insert(standard, spells['pyreshort'])
table.insert(standard, spells['venom'])
table.insert(standard, spells['magic'])
table.insert(standard, spells['decay'])
table.insert(standard, spells['haze'])
table.insert(standard, spells['grasp'])
table.insert(standard, spells['fireshadow'])
table.insert(standard, spells['leech'])
table.insert(standard, spells['grip'])
table.insert(standard, spells['pyrelong'])
table.insert(standard, spells['ignite'])
table.insert(standard, spells['scourge'])
table.insert(standard, spells['corruption'])

local short = {}
table.insert(short, spells['swarm'])
table.insert(short, spells['composite'])
table.insert(short, spells['pyreshort'])
table.insert(short, spells['venom'])
table.insert(short, spells['magic'])
table.insert(short, spells['decay'])
table.insert(short, spells['haze'])
table.insert(short, spells['grasp'])
table.insert(short, spells['fireshadow'])
table.insert(short, spells['leech'])
table.insert(short, spells['grip'])
table.insert(short, spells['pyrelong'])
table.insert(short, spells['ignite'])

local dots = {
    ['standard']=standard,
    ['short']=short,
}

-- Determine swap gem based on wherever wounds, broiling shadow or pyre of the wretched is currently mem'd
local swap_gem = mq.TLO.Me.Gem(spells['wounds']['name'])() or mq.TLO.Me.Gem(spells['fireshadow']['name'])() or mq.TLO.Me.Gem(spells['pyrelong']['name'])()
local swap_gem_dis = mq.TLO.Me.Gem(spells['decay']['name'])() or mq.TLO.Me.Gem(spells['grip']['name'])()

-- entries in the items table are MQ item datatypes
local items = {}
table.insert(items, mq.TLO.FindItem('Blightbringer\'s Tunic of the Grave').ID()) -- buff, 5 minute CD
table.insert(items, mq.TLO.InvSlot('Chest').Item.ID()) -- buff, Consuming Magic, 10 minute CD
table.insert(items, mq.TLO.FindItem('Rage of Rolfron').ID()) -- song, 30 minute CD
table.insert(items, mq.TLO.FindItem('Vicious Rabbit').ID()) -- 5 minute CD

local tcclickid = mq.TLO.FindItem('Bifold Focus of the Evil Eye').ID()

--table.insert(items, mq.TLO.FindItem('Necromantic Fingerbone').ID()) -- 3 minute CD
--table.insert(items, mq.TLO.FindItem('Amulet of the Drowned Mariner').ID()) -- 5 minute CD

local pre_burn_items = {}
table.insert(pre_burn_items, mq.TLO.FindItem('Blightbringer\'s Tunic of the Grave').ID()) -- buff
table.insert(pre_burn_items, mq.TLO.InvSlot('Chest').Item.ID()) -- buff, Consuming Magic

local function get_aaid_and_name(aa_name)
    return {['id']=mq.TLO.Me.AltAbility(aa_name).ID(), ['name']=aa_name}
end

-- entries in the AAs table are pairs of {aa name, aa id}
local AAs = {}
table.insert(AAs, get_aaid_and_name('Silent Casting')) -- song, 12 minute CD
table.insert(AAs, get_aaid_and_name('Focus of Arcanum')) -- buff, 10 minute CD
table.insert(AAs, get_aaid_and_name('Mercurial Torment')) -- buff, 24 minute CD
table.insert(AAs, get_aaid_and_name('Heretic\'s Twincast')) -- buff, 15 minute CD
table.insert(AAs, get_aaid_and_name('Spire of Necromancy')) -- buff, 7:30 minute CD
table.insert(AAs, get_aaid_and_name('Hand of Death')) -- song, 8:30 minute CD
table.insert(AAs, get_aaid_and_name('Funeral Pyre')) -- song, 20 minute CD
table.insert(AAs, get_aaid_and_name('Gathering Dusk')) -- song, Duskfall Empowerment, 10 minute CD
table.insert(AAs, get_aaid_and_name('Companion\'s Fury')) -- 10 minute CD
table.insert(AAs, get_aaid_and_name('Companion\'s Fortification')) -- 15 minute CD
table.insert(AAs, get_aaid_and_name('Rise of Bones')) -- 10 minute CD
table.insert(AAs, get_aaid_and_name('Wake the Dead')) -- 3 minute CD
table.insert(AAs, get_aaid_and_name('Swarm of Decay')) -- 9 minute CD

--table.insert(AAs, get_aaid_and_name('Life Burn')) -- 20 minute CD
--table.insert(AAs, get_aaid_and_name('Dying Grasp')) -- 20 minute CD

local glyph = get_aaid_and_name('Mythic Glyph of Ultimate Power V')
local intensity = get_aaid_and_name('Intensity of the Resolute')

local pre_burn_AAs = {}
table.insert(pre_burn_AAs, get_aaid_and_name('Focus of Arcanum')) -- buff
table.insert(pre_burn_AAs, get_aaid_and_name('Mercurial Torment')) -- buff
table.insert(pre_burn_AAs, get_aaid_and_name('Heretic\'s Twincast')) -- buff
table.insert(pre_burn_AAs, get_aaid_and_name('Spire of Necromancy')) -- buff

-- lifeburn/dying grasp combo
local lifeburn = get_aaid_and_name('Life Burn')
local dyinggrasp = get_aaid_and_name('Dying Grasp')
-- Buffs
local unity = get_aaid_and_name('Mortifier\'s Unity')
-- Mana Recovery AAs
local deathbloom = get_aaid_and_name('Death Bloom')
local bloodmagic = get_aaid_and_name('Blood Magic')
-- Mana Recovery items
--local item_feather = mq.TLO.FindItem('Unified Phoenix Feather')
--local item_horn = mq.TLO.FindItem('Miniature Horn of Unity') -- 10 minute CD
-- Agro
local deathpeace = get_aaid_and_name('Death Peace')
local deathseffigy = get_aaid_and_name('Death\'s Effigy')

local convergence = get_aaid_and_name('Convergence')

local buffs={
    ['self']={},
    ['pet']={
        spells['pethaste'],
        spells['petillusion'],
    },
}
--[[
    track data about our targets, for one-time or long-term affects.
    for example: we do not need to continually poll when to debuff a mob if the debuff will last 17+ minutes
    if the mob aint dead by then, you should re-roll a wizard.
]]--
local targets = {}

local neccount = 1

-- BEGIN lua table persistence
local write, writeIndent, writers, refCount;
local persistence =
{
	store = function (path, ...)
		local file, e = io.open(path, "w");
		if not file then
			return error(e);
		end
		local n = select("#", ...);
		-- Count references
		local objRefCount = {}; -- Stores reference that will be exported
		for i = 1, n do
			refCount(objRefCount, (select(i,...)));
		end;
		-- Export Objects with more than one ref and assign name
		-- First, create empty tables for each
		local objRefNames = {};
		local objRefIdx = 0;
		file:write("-- Persistent Data\n");
		file:write("local multiRefObjects = {\n");
		for obj, count in pairs(objRefCount) do
			if count > 1 then
				objRefIdx = objRefIdx + 1;
				objRefNames[obj] = objRefIdx;
				file:write("{};"); -- table objRefIdx
			end;
		end;
		file:write("\n} -- multiRefObjects\n");
		-- Then fill them (this requires all empty multiRefObjects to exist)
		for obj, idx in pairs(objRefNames) do
			for k, v in pairs(obj) do
				file:write("multiRefObjects["..idx.."][");
				write(file, k, 0, objRefNames);
				file:write("] = ");
				write(file, v, 0, objRefNames);
				file:write(";\n");
			end;
		end;
		-- Create the remaining objects
		for i = 1, n do
			file:write("local ".."obj"..i.." = ");
			write(file, (select(i,...)), 0, objRefNames);
			file:write("\n");
		end
		-- Return them
		if n > 0 then
			file:write("return obj1");
			for i = 2, n do
				file:write(" ,obj"..i);
			end;
			file:write("\n");
		else
			file:write("return\n");
		end;
		if type(path) == "string" then
			file:close();
		end;
	end;

	load = function (path)
		local f, e;
		if type(path) == "string" then
			f, e = loadfile(path);
		else
			f, e = path:read('*a')
		end
		if f then
			return f();
		else
			return nil, e;
		end;
	end;
}

-- Private methods

-- write thing (dispatcher)
write = function (file, item, level, objRefNames)
	writers[type(item)](file, item, level, objRefNames);
end;

-- write indent
writeIndent = function (file, level)
	for i = 1, level do
		file:write("\t");
	end;
end;

-- recursively count references
refCount = function (objRefCount, item)
	-- only count reference types (tables)
	if type(item) == "table" then
		-- Increase ref count
		if objRefCount[item] then
			objRefCount[item] = objRefCount[item] + 1;
		else
			objRefCount[item] = 1;
			-- If first encounter, traverse
			for k, v in pairs(item) do
				refCount(objRefCount, k);
				refCount(objRefCount, v);
			end;
		end;
	end;
end;

-- Format items for the purpose of restoring
writers = {
	["nil"] = function (file, item)
			file:write("nil");
		end;
	["number"] = function (file, item)
			file:write(tostring(item));
		end;
	["string"] = function (file, item)
			file:write(string.format("%q", item));
		end;
	["boolean"] = function (file, item)
			if item then
				file:write("true");
			else
				file:write("false");
			end
		end;
	["table"] = function (file, item, level, objRefNames)
			local refIdx = objRefNames[item];
			if refIdx then
				-- Table with multiple references
				file:write("multiRefObjects["..refIdx.."]");
			else
				-- Single use table
				file:write("{\n");
				for k, v in pairs(item) do
					writeIndent(file, level+1);
					file:write("[");
					write(file, k, level+1, objRefNames);
					file:write("] = ");
					write(file, v, level+1, objRefNames);
					file:write(";\n");
				end
				writeIndent(file, level);
				file:write("}");
			end;
		end;
	["function"] = function (file, item)
			-- Does only work for "normal" functions, not those
			-- with upvalues or c functions
			local dInfo = debug.getinfo(item, "uS");
			if dInfo.nups > 0 then
				file:write("nil --[[functions with upvalue not supported]]");
			elseif dInfo.what ~= "Lua" then
				file:write("nil --[[non-lua function not supported]]");
			else
				local r, s = pcall(string.dump,item);
				if r then
					file:write(string.format("loadstring(%q)", s));
				else
					file:write("nil --[[function could not be dumped]]");
				end
			end
		end;
	["thread"] = function (file, item)
			file:write("nil --[[thread]]\n");
		end;
	["userdata"] = function (file, item)
			file:write("nil --[[userdata]]\n");
		end;
}
-- END lua table persistence

local function file_exists(file_name)
    local f = io.open(file_name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

local SETTINGS_FILE = ('%s/necrobot_%s_%s.lua'):format(mq.configDir, mq.TLO.EverQuest.Server(), mq.TLO.Me.CleanName())
local function load_settings()
    if not file_exists(SETTINGS_FILE) then return end
    local settings = assert(loadfile(SETTINGS_FILE))()
    if settings['MODE'] ~= nil then OPTS.MODE = settings['MODE'] end
    if settings['CHASETARGET'] ~= nil then OPTS.CHASETARGET = settings['CHASETARGET'] end
    if settings['CHASEDISTANCE'] ~= nil then OPTS.CHASEDISTANCE = settings['CHASEDISTANCE'] end
    if settings['CAMPRADIUS'] ~= nil then OPTS.CAMPRADIUS = settings['CAMPRADIUS'] end
    if settings['ASSIST'] ~= nil then OPTS.ASSIST = settings['ASSIST'] end
    if settings['AUTOASSISTAT'] ~= nil then OPTS.AUTOASSISTAT = settings['AUTOASSISTAT'] end
    if settings['STOPPCT'] ~= nil then OPTS.STOPPCT = settings['STOPPCT'] end
    if settings['SPELLSET'] ~= nil then OPTS.SPELLSET = settings['SPELLSET'] end
    if settings['BURNALWAYS'] ~= nil then OPTS.BURNALWAYS = settings['BURNALWAYS'] end
    if settings['BURNPCT'] ~= nil then OPTS.BURNPCT = settings['BURNPCT'] end
    if settings['BURNALLNAMED'] ~= nil then OPTS.BURNALLNAMED = settings['BURNALLNAMED'] end
    if settings['BURNPROC'] ~= nil then OPTS.BURNPROC = settings['BURNPROC'] end
    if settings['BURNCOUNT'] ~= nil then OPTS.BURNCOUNT = settings['BURNCOUNT'] end
    if settings['DEBUFF'] ~= nil then OPTS.DEBUFF = settings['DEBUFF'] end
    if settings['USEALLIANCE'] ~= nil then OPTS.USEALLIANCE = settings['USEALLIANCE'] end
    if settings['SWITCHWITHMA'] ~= nil then OPTS.SWITCHWITHMA = settings['SWITCHWITHMA'] end
    if settings['SUMMONPET'] ~= nil then OPTS.SUMMONPET = settings['SUMMONPET'] end
    if settings['BUFFPET'] ~= nil then OPTS.BUFFPET = settings['BUFFPET'] end
    if settings['USEBUFFSHIELD'] ~= nil then OPTS.USEBUFFSHIELD = settings['USEBUFFSHIELD'] end
    if settings['USEMANATAP'] ~= nil then OPTS.USEMANATAP = settings['USEMANATAP'] end
    if settings['USEFD'] ~= nil then OPTS.USEFD = settings['USEFD'] end
    if settings['USEINSPIRE'] ~= nil then OPTS.USEINSPIRE = settings['USEINSPIRE'] end
    if settings['USEREZ'] ~= nil then OPTS.USEREZ = settings['USEREZ'] end
    if settings['USEWOUNDS'] ~= nil then OPTS.USEWOUNDS = settings['USEWOUNDS'] end
    if settings['MULTIDOT'] ~= nil then OPTS.MULTIDOT = settings['MULTIDOT'] end
    if settings['MULTICOUNT'] ~= nil then OPTS.MULTICOUNT = settings['MULTICOUNT'] end
    if settings['USEGLYPH'] ~= nil then OPTS.USEGLYPH = settings['USEGLYPH'] end
    if settings['USEINTENSITY'] ~= nil then OPTS.USEINTENSITY = settings['USEINTENSITY'] end
end

local function save_settings()
    persistence.store(SETTINGS_FILE, OPTS)
end

--[[
Count the number of necros in group or raid to determine whether alliance should be used.
This is currently only called once up front when the script starts.
]]--
local function get_necro_count()
    neccount = 1
    if mq.TLO.Raid.Members() > 0 then
        neccount = mq.TLO.SpawnCount('pc necromancer raid')()
    elseif mq.TLO.Group.Members() then
        neccount = mq.TLO.SpawnCount('pc necromancer group')()
    end
end

-- Check that we are not currently casting anything
local function can_cast_weave()
    return not mq.TLO.Me.Casting()
end

-- Check whether a dot is applied to the target
local function is_target_dotted_with(spell_id, spell_name)
    if not mq.TLO.Target.MyBuff(spell_name)() then return false end

    -- special case for septic proliferation since rankname just returns "septic proliferation"
    if spells['proliferation']['name']:find(spell_name) then return true end
    return spell_id == mq.TLO.Target.MyBuff(spell_name).ID()
end

local function is_dot_ready(spellId, spellName)
    local buffDuration = 0
    local remainingCastTime = 0
    if not mq.TLO.Me.SpellReady(spellName)() then
        return false
    end

    if mq.TLO.Spell(spellName).Mana() > mq.TLO.Me.CurrentMana() then
        return false
    end
    buffDuration = mq.TLO.Target.MyBuffDuration(spellName)()
    if not is_target_dotted_with(spellId, spellName) then
        -- target does not have the dot, we are ready
        return true
    else
        if not buffDuration then
            return true
        end
        -- Do not return wounds as ready while it still has any duration left
        if spellId == spells['wounds']['id'] then return false end
        remainingCastTime = mq.TLO.Spell(spellName).MyCastTime()
        return buffDuration < remainingCastTime + 3000
    end

    return false
end

local function is_fighting() 
    --if mq.TLO.Target.CleanName() == 'Combat Dummy Beza' then return true end -- Dev hook for target dummy
    return (mq.TLO.Target.ID() ~= nil and (mq.TLO.Me.CombatState() ~= "ACTIVE" and mq.TLO.Me.CombatState() ~= "RESTING") and mq.TLO.Me.Standing() and not mq.TLO.Me.Feigning() and mq.TLO.Target.Type() == "NPC" and mq.TLO.Target.Type() ~= "Corpse")
end

local function check_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

local function am_i_dead()
    if I_AM_DEAD and (mq.TLO.Me.Buff('Resurrection Sickness').ID() or mq.TLO.SpawnCount('pccorpse '..mq.TLO.Me.CleanName())() == 0) then
        I_AM_DEAD = false
    end
    return I_AM_DEAD
end

local function check_chase()
    if OPTS.MODE ~= 'chase' then return end
    if am_i_dead() then return end
    local chase_spawn = mq.TLO.Spawn('pc ='..OPTS.CHASETARGET)
    local me_x = mq.TLO.Me.X()
    local me_y = mq.TLO.Me.Y()
    local chase_x = chase_spawn.X()
    local chase_y = chase_spawn.Y()
    if not chase_x or not chase_y then return end
    if check_distance(me_x, me_y, chase_x, chase_y) > OPTS.CHASEDISTANCE then
        if not mq.TLO.Nav.Active() then
            mq.cmdf('/nav spawn pc =%s | log=off', OPTS.CHASETARGET)
        end
    end
end

local function check_camp()
    if OPTS.MODE ~= 'assist' then return end
    if am_i_dead() then return end
    if is_fighting() or not CAMP then return end
    if mq.TLO.Zone.ID() ~= CAMP.ZoneID then
        printf('Clearing camp as we have zoned.')
        CAMP = nil
        return
    end
    if check_distance(mq.TLO.Me.X(), mq.TLO.Me.Y(), CAMP.X, CAMP.Y) > 15 then
        if not mq.TLO.Nav.Active() then
            mq.cmdf('/nav locyxz %d %d %d', CAMP.Y, CAMP.X, CAMP.Z)
        end
    end
end

local function set_camp(reset)
    if (OPTS.MODE == 'assist' and not CAMP) or reset then
        CAMP = {
            ['X']=mq.TLO.Me.X(),
            ['Y']=mq.TLO.Me.Y(),
            ['Z']=mq.TLO.Me.Z(),
            ['ZoneID']=mq.TLO.Zone.ID()
        }
        mq.cmdf('/mapf campradius %d', OPTS.CAMPRADIUS)
    elseif OPTS.MODE ~= 'assist' and CAMP then
        CAMP = nil
        mq.cmd('/mapf campradius 0')
    end
end

local function get_assist_spawn()
    local assist_target = nil
    if OPTS.ASSIST == 'group' then
        assist_target = mq.TLO.Me.GroupAssistTarget
    elseif OPTS.ASSIST == 'raid1' then
        assist_target = mq.TLO.Me.RaidAssistTarget(1)
    elseif OPTS.ASSIST == 'raid2' then
        assist_target = mq.TLO.Me.RaidAssistTarget(2)
    elseif OPTS.ASSIST == 'raid3' then
        assist_target = mq.TLO.Me.RaidAssistTarget(3)
    end
    return assist_target
end

local function should_assist(assist_target)
    if not assist_target then assist_target = get_assist_spawn() end
    if not assist_target then return false end
    local id = assist_target.ID()
    local hp = assist_target.PctHPs()
    local mob_type = assist_target.Type()
    local mob_x = assist_target.X()
    local mob_y = assist_target.Y()
    if not id or id == 0 or not hp or hp == 0 or not mob_x or not mob_y then return false end
    if mob_type == 'NPC' and hp < OPTS.AUTOASSISTAT then
        if CAMP and check_distance(CAMP.X, CAMP.Y, mob_x, mob_y) <= OPTS.CAMPRADIUS then
            return true
        elseif not CAMP and check_distance(mq.TLO.Me.X(), mq.TLO.Me.Y(), mob_x, mob_y) <= OPTS.CAMPRADIUS then
            return true
        end
    else
        return false
    end
end

local function check_target()
    if am_i_dead() then return end
    if OPTS.MODE ~= 'manual' or OPTS.SWITCHWITHMA then
        local assist_target = get_assist_spawn()
        if not assist_target() then return end
        if mq.TLO.Target() and mq.TLO.Target.Type() == 'NPC' and assist_target.ID() == mq.TLO.Group.MainAssist.ID() then
            mq.cmd('/target clear')
            mq.cmd('/pet back')
            return
        end
        if is_fighting() and not OPTS.SWITCHWITHMA then return end
        if mq.TLO.Target.ID() ~= assist_target.ID() and should_assist(assist_target) then
            assist_target.DoTarget()
            mq.delay(5)
            printf('Assisting on >>> \ay%s\ax <<<', mq.TLO.Target.CleanName())
        end
    end
end

local function check_target_multi()
    if am_i_dead() then return end
    if OPTS.MODE ~= 'manual' then
        local most_dots = 100
        for _,details in pairs(DOT_TARGETS) do
            if details.dots > most_dots then
                most_dots = details.dots
            end
        end
        for i=1,13 do
            if mq.TLO.Me.XTarget(i).TargetType() == 'Auto Hater' and mq.TLO.Me.XTarget(i).Type() == 'NPC' then
                local xtar_id = mq.TLO.Me.XTarget(i).ID()
                local xtar_spawn = mq.TLO.Spawn(xtar_id)
                local xtar_hp = xtar_spawn.PctHPs()
                if xtar_spawn and xtar_hp and xtar_hp <= OPTS.AUTOASSISTAT then
                    if DOT_TARGETS[xtar_id] then
                        -- this xtarget is already being tracked
                        if DOT_TARGETS[xtar_id].mezzed and os.difftime(os.time(os.date("!*t")), DOT_TARGETS[xtar_id].mezzed) > 10 then
                            -- this xtarget is mezzed, so check timer to see if we should re-check it
                            mq.cmdf('/mqtar %s', xtar_id)
                            mq.delay(500, function() return mq.TLO.Target.ID() == xtar_id end)
                            if mq.TLO.Target.Mezzed() then
                                -- target still mezzed, reset timer
                                DOT_TARGETS[xtar_id].mezzed = os.time(os.date("!*t"))
                            else
                                -- targets no longer mezzed, maybe can dps it now
                                DOT_TARGETS[xtar_id].mezzed = nil
                                if should_assist(mq.TLO.Target) then
                                    return
                                end
                            end
                        elseif should_assist(mq.TLO.Spawn(xtar_id)) and DOT_TARGETS[xtar_id].dots < most_dots then
                            -- this xtarget is not mezzed, is it due for dotting?
                            mq.cmdf('/mqtar %s', xtar_id)
                            mq.delay(500, function() return mq.TLO.Target.ID() == xtar_id end)
                            return
                        end
                    else
                        -- this xtarget isn't being tracked yet. check if its mezzed or can be attacked
                        mq.cmdf('/mqtar %s', xtar_id)
                        mq.delay(500, function() return mq.TLO.Target.ID() == xtar_id end)
                        local target = mq.TLO.Target
                        if should_assist(target) then
                            DOT_TARGETS[xtar_id] = {dots=0}
                            if target.Mezzed() then
                                DOT_TARGETS[xtar_id].mezzed = os.time(os.date("!*t"))
                            else
                                -- acquired a new xtarget we can dot
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end

local function prune_dot_targets()
    for id,details in pairs(DOT_TARGETS) do
        local spawn = mq.TLO.Spawn(id)
        if not spawn() or spawn.Type() ~= 'NPC' then
            DOT_TARGETS[id] = nil
        end
    end
end

local function in_control()
    return not mq.TLO.Me.Moving() and not mq.TLO.Me.Stunned() and not mq.TLO.Me.Silenced() and not mq.TLO.Me.Feigning() and not mq.TLO.Me.Mezzed() and not mq.TLO.Me.Invulnerable() and not mq.TLO.Me.Hovering()
end

local function cast(spell_name, requires_target, requires_los)
    if not in_control() or (requires_los and not mq.TLO.Target.LineOfSight()) then return end
    printf('Casting \ar%s\ax', spell_name)
    mq.cmdf('/cast "%s"', spell_name)
    mq.delay(10)
    if not mq.TLO.Me.Casting() then mq.cmdf('/cast %s', spell_name) end
    mq.delay(10)
    if not mq.TLO.Me.Casting() then mq.cmdf('/cast %s', spell_name) end
    mq.delay(10)
    while mq.TLO.Me.Casting() do
        if requires_target and not mq.TLO.Target() then
            mq.cmd('/stopcast')
            break
        end
        mq.delay(10)
    end
    --local id = mq.TLO.Target.ID()
    --if id and id > 0 then
    --    DOT_TARGETS[id].dots = DOT_TARGETS[id].dots + 1
    --end
end

-- Casts alliance if we are fighting, alliance is enabled, the spell is ready, alliance isn't already on the mob, there is > 1 necro in group or raid, and we have at least a few dots on the mob.
local function try_alliance()
    if OPTS.USEALLIANCE then
        if mq.TLO.Spell(spells['alliance']['name']).Mana() > mq.TLO.Me.CurrentMana() then
            return false
        end
        if mq.TLO.Me.SpellReady(spells['alliance']['name'])() and neccount > 1 and not mq.TLO.Target.Buff(spells['alliance']['name'])() and mq.TLO.Spell(spells['alliance']['name']).StacksTarget() then
            -- pick the first 3 dots in the rotation as they will hopefully always be up given their priority
            if mq.TLO.Target.MyBuff(spells['pyreshort']['name'])() and mq.TLO.Target.MyBuff(spells['venom']['name'])() and mq.TLO.Target.MyBuff(spells['magic']['name'])() then
                cast(spells['alliance']['name'], true, true)
                return true
            end
        end
    end
    return false
end

local function cast_synergy()
    if not mq.TLO.Me.Song('Defiler\'s Synergy')() and mq.TLO.Me.SpellReady(spells['synergy']['name'])() then
        if mq.TLO.Spell(spells['synergy']['name']).Mana() > mq.TLO.Me.CurrentMana() then
            return false
        end
        -- don't bother with proc'ing synergy until we've got most dots applied
        if mq.TLO.Target.MyBuff(spells['pyreshort']['name'])() and mq.TLO.Target.MyBuff(spells['venom']['name'])() and mq.TLO.Target.MyBuff(spells['magic']['name'])() then
            cast(spells['synergy']['name'], true, true)
            return true
        end
    end
    return false
end

local function find_next_dot_to_cast()
    if try_alliance() then return nil end
    if cast_synergy() then return nil end
    -- Just cast composite as part of the normal dot rotation, no special handling
    --if is_dot_ready(spells['composite']['id'], spells['composite']['name']) then
    --    return spells['composite']['id'], spells['composite']['name']
    --end
    if OPTS.SPELLSET == 'short' and mq.TLO.Me.SpellReady(spells['swarm']['name'])() and mq.TLO.Spell(spells['swarm']['name']).Mana() < mq.TLO.Me.CurrentMana() then
        return spells['swarm']
    end
    if mq.TLO.Me.PctMana() < 40 and mq.TLO.Me.SpellReady(spells['manatap']['name'])() and mq.TLO.Spell(spells['manatap']['name']).Mana() < mq.TLO.Me.CurrentMana() then
        return spells['manatap']
    end
    local pct_hp = mq.TLO.Target.PctHPs()
    if pct_hp and pct_hp > OPTS.STOPPCT then
        for _,dot in ipairs(dots[OPTS.SPELLSET]) do -- iterates over the dots array. ipairs(dots) returns 2 values, an index and its value in the array. we don't care about the index, we just want the dot
            local spell_id = dot['id']
            local spell_name = dot['name']
            -- ToL has no combo disease dot spell, so the 2 disease dots are just in the normal rotation now.
            -- if spell_id == spells['combodis']['id'] then
            --     if (not is_target_dotted_with(spells['decay']['id'], spells['decay']['name']) or not is_target_dotted_with(spells['grip']['id'], spells['grip']['name'])) and mq.TLO.Me.SpellReady(spells['combodis']['name'])() then
            --         return dot
            --     end
            -- else
            if (OPTS.USEWOUNDS or spell_name ~= spells['wounds']['name']) and is_dot_ready(spell_id, spell_name) then
                return dot -- if is_dot_ready returned true then return this dot as the dot we should cast
            end
        end
    end
    if mq.TLO.Me.SpellReady(spells['manatap']['name'])() and mq.TLO.Spell(spells['manatap']['name']).Mana() < mq.TLO.Me.CurrentMana() then
        return spells['manatap']
    end
    if OPTS.SPELLSET == 'short' and mq.TLO.Me.SpellReady(spells['venin']['name'])() and mq.TLO.Spell(spells['venin']['name']).Mana() < mq.TLO.Me.CurrentMana() then
        return spells['venin']
    end
    return nil -- we found no missing dot that was ready to cast, so return nothing
end

local function use_item(item)
    if item() and item.Clicky.Spell() and item.Timer() == '0' then
        if item.Clicky.Spell.TargetType() == 'Single' and not mq.TLO.Target() then return end
        if can_cast_weave() then
            printf('use_item: \ax\ar%s\ax', item)
            mq.cmdf('/useitem "%s"', item)
        end
        mq.delay(300+item.CastTime()) -- wait for cast time + some buffer so we don't skip over stuff
        -- alternatively maybe while loop until we see the buff or song is applied
    end
end

local function cycle_dots()
    --if is_fighting() or (not OPTS.MULTIDOT and should_assist()) then
    if not mq.TLO.Me.SpellInCooldown() and (is_fighting() or should_assist()) then
        local spell = find_next_dot_to_cast() -- find the first available dot to cast that is missing from the target
        if spell then -- if a dot was found
            if spell['name'] == spells['pyreshort']['name'] and not mq.TLO.Me.Buff('Heretic\'s Twincast')() then
                local tcclick = mq.TLO.FindItem(tcclickid)
                use_item(tcclick)
            end
            cast(spell['name'], true, true) -- then cast the dot
        end
        if OPTS.MULTIDOT then
            local original_target_id = 0
            if mq.TLO.Target.Type() == 'NPC' then original_target_id = mq.TLO.Target.ID() end
            local dotted_count = 1
            for i=1,13 do
                if mq.TLO.Me.XTarget(i).TargetType() == 'Auto Hater' and mq.TLO.Me.XTarget(i).Type() == 'NPC' then
                    local xtar_id = mq.TLO.Me.XTarget(i).ID()
                    local xtar_spawn = mq.TLO.Spawn(xtar_id)
                    if xtar_id ~= original_target_id and should_assist(xtar_spawn) then
                        xtar_spawn.DoTarget()
                        mq.delay(2000, function() return mq.TLO.Target.ID() == xtar_id and not mq.TLO.Me.SpellInCooldown() end)
                        local spell = find_next_dot_to_cast() -- find the first available dot to cast that is missing from the target
                        if spell and not mq.TLO.Target.Mezzed() then -- if a dot was found
                            --if not mq.TLO.Me.SpellReady(spell['name'])() then break end
                            cast(spell['name'], true, true)
                            dotted_count = dotted_count + 1
                            if dotted_count >= OPTS.MULTICOUNT then break end
                        end
                    end
                end
            end
            if original_target_id ~= 0 and mq.TLO.Target.ID() ~= original_target_id then
                mq.cmdf('/mqtar id %s', original_target_id)
            end
        end
        return true
    end
    return false
end

local function try_debuff_target()
    if (is_fighting() or should_assist()) and OPTS.DEBUFF then
        local targetID = mq.TLO.Target.ID()
        if targetID and targetID > 0 and (not targets[targetID] or not targets[targetID][2]) then
            local isScentAAReady = mq.TLO.Me.AltAbilityReady('Scent of Thule')()

            local isDebuffedAlready = is_target_dotted_with(spells['scentterris']['id'], spells['scentterris']['name'])
            if isDebuffedAlready then
                isDebuffedAlready = is_target_dotted_with(spells['scentmortality']['id'], spells['scentmortality']['name'])
            end
            if not mq.TLO.Spell(spells['scentterris']['name']).StacksTarget() then
                isDebuffedAlready = true
            end
            if not mq.TLO.Spell(spells['scentmortality']['name']).StacksTarget() then
                isDebuffedAlready = true
            end

            if isScentAAReady and not isDebuffedAlready then
                printf('use_aa: \ax\arScent of Thule\ax')
                mq.cmd('/alt activate 751')
                mq.delay(10)
            end

            if isDebuffedAlready then
                table.insert(targets, mq.TLO.Target.ID(), {"debuffed", true})
            end
            mq.delay(300+mq.TLO.Me.AltAbility(751).Spell.CastTime()) -- wait for cast time + some buffer so we don't skip over stuff
        end
    end
end

local send_pet_timer = 0
local function send_pet()
    if not mq.TLO.Pet() then return end
    if os.difftime(os.time(os.date("!*t")), send_pet_timer) > 1 and (is_fighting() or should_assist()) then
        if mq.TLO.Pet.Target.ID() ~= mq.TLO.Target.ID() then
            mq.cmd('/multiline ; /pet attack ; /pet swarm ;')
            send_pet_timer = os.time(os.date("!*t"))
        end
    end
end

local function check_los()
    if OPTS.MODE ~= 'manual' and (is_fighting() or should_assist()) then
        if not mq.TLO.Target.LineOfSight() and not mq.TLO.Navigation.Active() then
            mq.cmd('/nav target log=off')
        end
    end
end

local function use_aa(aa, number)
    if not mq.TLO.Me.Song(aa)() and not mq.TLO.Me.Buff(aa)() and mq.TLO.Me.AltAbilityReady(aa)() and can_cast_weave() then
        if mq.TLO.Me.AltAbility(aa).Spell.TargetType() == 'Single' and not mq.TLO.Target() then return end
        if mq.TLO.Me.AltAbility(aa).Spell.TargetType() == 'Pet' and mq.TLO.Pet.ID() == 0 then return end
        if can_cast_weave() then
            printf('use_aa: \ax\ar%s\ax', aa)
            mq.cmdf('/alt activate %d', number)
        end
        mq.delay(300+mq.TLO.Me.AltAbility(aa).Spell.CastTime()) -- wait for cast time + some buffer so we don't skip over stuff
        -- alternatively maybe while loop until we see the buff or song is applied, but not all apply a buff or song, like pet stuff
    end
end

local burn_active_timer = 0
local burn_active = false
local function is_burn_condition_met()
    -- activating a burn condition is good for 60 seconds, don't do check again if 60 seconds hasn't passed yet and burn is active.
    if os.difftime(os.time(os.date("!*t")), burn_active_timer) < 30 and burn_active then
        return true
    else
        burn_active = false
    end
    if BURN_NOW then
        printf('\arActivating Burns (on demand)\ax')
        burn_active_timer = os.time(os.date("!*t"))
        burn_active = true
        BURN_NOW = false
        return true
    elseif is_fighting() then
        if OPTS.BURNALWAYS then
            -- With burn always, save twincast for when hand of death is ready, otherwise let other burns fire
            if mq.TLO.Me.AltAbilityReady('Heretic\'s Twincast')() and not mq.TLO.Me.AltAbilityReady('Hand of Death')() then
                return false
            elseif not mq.TLO.Me.AltAbilityReady('Heretic\'s Twincast')() and mq.TLO.Me.AltAbilityReady('Hand of Death')() then
                return false
            else
                return true
            end
        elseif OPTS.BURNALLNAMED and mq.TLO.Target.Named() then
            printf('\arActivating Burns (named)\ax')
            burn_active_timer = os.time(os.date("!*t"))
            burn_active = true
            return true
        elseif OPTS.BURNPROC and is_target_dotted_with(spells['proliferation']['id'], spells['proliferation']['name']) then
            printf('\arActivating Burns (proliferation proc)\ax')
            burn_active_timer = os.time(os.date("!*t"))
            burn_active = true
            return true
        elseif mq.TLO.SpawnCount(string.format('xtarhater radius %d zradius 50', OPTS.CAMPRADIUS))() >= OPTS.BURNCOUNT then
            printf('\arActivating Burns (mob count > %d)\ax', OPTS.BURNCOUNT)
            burn_active_timer = os.time(os.date("!*t"))
            burn_active = true
            return true
        elseif OPTS.BURNPCT ~= 0 and mq.TLO.Target.PctHPs() < OPTS.BURNPCT then
            printf('\arActivating Burns (percent HP)\ax')
            burn_active_timer = os.time(os.date("!*t"))
            burn_active = true
            return true
        end
    end
    burn_active_timer = 0
    burn_active = false
    return false
end

--[[
Base crit - 62%

Auspice - 33% crit
IOG - 13% crit
Bard Epic (12) + Fierce Eye (15) - 27% crit

Spire - 25% crit
OOW robe - 40% crit
Intensity - 50% crit
Glyph - 15% crit
]]--
local function try_burn()
    -- Some items use Timer() and some use IsItemReady(), this seems to be mixed bag.
    -- Test them both for each item, and see which one(s) actually work.
    if is_burn_condition_met() then
        local base_crit = 62
        local auspice = mq.TLO.Me.Song('Auspice of the Hunter')()
        if auspice then base_crit = base_crit + 33 end
        local iog = mq.TLO.Me.Song('Illusions of Grandeur')()
        if iog then base_crit = base_crit + 13 end
        local brd_epic = mq.TLO.Me.Song('Spirit of Vesagran')()
        if brd_epic then base_crit = base_crit + 12 end
        local fierce_eye = mq.TLO.Me.Song('Fierce Eye')()
        if fierce_eye then base_crit = base_crit + 15 end

        --[[
        |===========================================================================================
        |Item Burn
        |===========================================================================================
        ]]--

        for _,item_id in ipairs(items) do
            local item = mq.TLO.FindItem(item_id)
            if item.Name() ~= 'Blightbringer\'s Tunic of the Grave' or base_crit < 100 then
                use_item(item)
            end
        end

        --[[
        |===========================================================================================
        |Spell Burn
        |===========================================================================================
        ]]--

        for _,aa in ipairs(AAs) do
            -- don't go making twincast dots sad by cutting them in half
            if aa['name']:lower() == 'funeral pyre' then
                if not mq.TLO.Me.AltAbilityReady('heretic\'s twincast')() and not mq.TLO.Me.Buff('heretic\'s twincast')() then
                    use_aa(aa['name'], aa['id'])
                end
            elseif aa['name']:lower() == 'wake the dead' then
                if mq.TLO.SpawnCount('corpse radius 150')() > 0 then
                    use_aa(aa['name'], aa['id'])
                end
            else
                use_aa(aa['name'], aa['id'])
            end
        end
        if OPTS.USEGLYPH then
            if not mq.TLO.Me.Song(intensity['name'])() and mq.TLO.Me.Buff('heretic\'s twincast')() then
                use_aa(glyph['name'], glyph['id'])
            end
        end
        if OPTS.USEINTENSITY then
            if not mq.TLO.Me.Buff(glyph['name'])() and mq.TLO.Me.Buff('heretic\'s twincast')() then
                use_aa(intensity['name'], intensity['id'])
            end
        end

        if mq.TLO.Me.PctHPs() > 90 and mq.TLO.Me.AltAbilityReady('Life Burn')() and mq.TLO.Me.AltAbilityReady('Dying Grasp')() then
            use_aa(lifeburn['name'], lifeburn['id'])
            mq.delay(5)
            use_aa(dyinggrasp['name'], dyinggrasp['id'])
        end
    end
end

local function pre_pop_burns()
    printf('Pre-burn')
    --[[
    |===========================================================================================
    |Item Burn
    |===========================================================================================
    ]]--

    for _,item_id in ipairs(pre_burn_items) do
        local item = mq.TLO.FindItem(item_id)
        use_item(item)
    end

    --[[
    |===========================================================================================
    |Spell Burn
    |===========================================================================================
    ]]--

    for _,aa in ipairs(pre_burn_AAs) do
        use_aa(aa['name'], aa['id'])
    end

    if OPTS.USEGLYPH then
        if not mq.TLO.Me.Song(intensity['name'])() and mq.TLO.Me.Buff('heretic\'s twincast')() then
            use_aa(glyph['name'], glyph['id'])
        end
    end
end

local function check_mana()
    -- modrods
    local pct_mana = mq.TLO.Me.PctMana()
    if pct_mana < 90 then
        -- Find ModRods in check_mana since they poof when out of charges, can't just find once at startup.
        local item_aa_modrod = mq.TLO.FindItem('Summoned: Dazzling Modulation Shard') or mq.TLO.FindItem('Summoned: Radiant Modulation Shard')
        use_item(item_aa_modrod)
        local item_wand_modrod = mq.TLO.FindItem('Wand of Restless Modulation')
        use_item(item_wand_modrod)
        local item_wand_old = mq.TLO.FindItem('Wand of Phantasmal Transvergence')
        use_item(item_wand_old)
    end
    if pct_mana < 89 then
        -- death bloom at some %
        use_aa(deathbloom['name'], deathbloom['id'])
    end
    if is_fighting() then
        if pct_mana < 70 then
            -- blood magic at some %
            use_aa(bloodmagic['name'], bloodmagic['id'])
        end
    end
    -- unified phoenix feather
end

local function safe_to_stand()
    if mq.TLO.Raid.Members() > 0 and mq.TLO.SpawnCount('pc raid tank radius 300')() > 2 then
        return true
    end
    if mq.TLO.Group.MainTank() then
        if not mq.TLO.Group.MainTank.Dead() then
            return true
        elseif mq.TLO.SpawnCount('npc radius 100')() == 0 then
            return true
        else
            return false
        end
    elseif mq.TLO.SpawnCount('npc radius 100')() == 0 then
        return true
    else
        return false
    end
end

local check_aggro_timer = 0
local function check_aggro()
    if OPTS.USEFD and is_fighting() and mq.TLO.Target() then
        if mq.TLO.Me.TargetOfTarget.ID() == mq.TLO.Me.ID() or os.difftime(os.time(os.date("!*t")), check_aggro_timer) > 10 then
            if mq.TLO.Me.PctAggro() >= 90 then
                if mq.TLO.Me.PctHPs() < 40 and mq.TLO.Me.AltAbilityReady('Dying Grasp')() then
                    use_aa(dyinggrasp['name'], dyinggrasp['id'])
                end
                use_aa(deathseffigy['name'], deathseffigy['id'])
                if mq.TLO.Me.Feigning() then
                    check_aggro_timer = os.time(os.date("!*t"))
                    mq.delay(500)
                    if safe_to_stand() then
                        mq.TLO.Me.Sit() -- Use a sit TLO to stand up, what wizardry is this?
                        mq.cmd('/makemevis')
                    end
                end
            elseif mq.TLO.Me.PctAggro() >= 70 then
                use_aa(deathpeace['name'], deathpeace['id'])
                if mq.TLO.Me.Feigning() then
                    check_aggro_timer = os.time(os.date("!*t"))
                    mq.delay(500)
                    if safe_to_stand() then
                        mq.TLO.Me.Sit() -- Use a sit TLO to stand up, what wizardry is this?
                        mq.cmd('/makemevis')
                    end
                end
            end
        end
    end
end

local rez_timer = 0
local function check_rez()
    if not OPTS.USEREZ or am_i_dead() then return end
    if os.difftime(os.time(os.date("!*t")), rez_timer) < 5 then return end
    if not mq.TLO.Me.AltAbilityReady(convergence['name'])() then return end
    if mq.TLO.FindItemCount('=Essence Emerald')() == 0 then return end
    if mq.TLO.SpawnCount('pccorpse group healer radius 100')() > 0 then
        mq.TLO.Spawn('pccorpse group healer radius 100').DoTarget()
        mq.cmd('/corpse')
        use_aa(convergence['name'], convergence['id'])
        rez_timer = os.time(os.date("!*t"))
        return
    end
    if mq.TLO.SpawnCount('pccorpse raid healer radius 100')() > 0 then
        mq.TLO.Spawn('pccorpse raid healer radius 100').DoTarget()
        mq.cmd('/corpse')
        use_aa(convergence['name'], convergence['id'])
        rez_timer = os.time(os.date("!*t"))
        return
    end
    if mq.TLO.Group.MainTank() and mq.TLO.Group.MainTank.Dead() then
        mq.TLO.Group.MainTank.DoTarget()
        local corpse_x = mq.TLO.Target.X()
        local corpse_y = mq.TLO.Target.Y()
        if corpse_x and corpse_y and check_distance(mq.TLO.Me.X(), mq.TLO.Me.Y(), corpse_x, corpse_y) > 100 then return end
        mq.cmd('/corpse')
        use_aa(convergence['name'], convergence['id'])
        rez_timer = os.time(os.date("!*t"))
        return
    end
    for i=1,5 do
        if mq.TLO.Group.Member(i)() and mq.TLO.Group.Member(i).Dead() then
            mq.TLO.Group.Member(i).DoTarget()
            local corpse_x = mq.TLO.Target.X()
            local corpse_y = mq.TLO.Target.Y()
            if corpse_x and corpse_y and check_distance(mq.TLO.Me.X(), mq.TLO.Me.Y(), corpse_x, corpse_y) < 100 then
                mq.cmd('/corpse')
                use_aa(convergence['name'], convergence['id'])
                rez_timer = os.time(os.date("!*t"))
                return
            end
        end
    end
end

local function rest()
    if not is_fighting() and not mq.TLO.Me.Sitting() and not mq.TLO.Me.Moving() and mq.TLO.Me.PctMana() < 60 and not mq.TLO.Me.Casting() and mq.TLO.SpawnCount(string.format('xtarhater radius %d zradius 50', OPTS.CAMPRADIUS))() == 0 then
        mq.cmd('/sit')
    end
end

local function swap_gem_ready(spell_name, gem)
    return mq.TLO.Me.Gem(gem)() and mq.TLO.Me.Gem(gem).Name() == spell_name
end

local function swap_spell(spell_name, gem)
    if not gem or am_i_dead() then return end
    mq.cmdf('/memspell %d "%s"', gem, spell_name)
    mq.delay('3s', swap_gem_ready(spell_name, gem))
    mq.TLO.Window('SpellBookWnd').DoClose()
end

local function check_buffs()
    if am_i_dead() or mq.TLO.Me.Moving() then return end
    if not mq.TLO.Me.Buff('Geomantra')() then
        use_item(mq.TLO.InvSlot('Charm').Item)
    end
    if OPTS.USEBUFFSHIELD then
        if not mq.TLO.Me.Buff(spells['shield']['name'])() and mq.TLO.Me.SpellReady(spells['shield']['name'])() and mq.TLO.Spell(spells['shield']['name']).Mana() < mq.TLO.Me.CurrentMana() then
            cast(spells['shield']['name'])
        end
    end
    if OPTS.USEINSPIRE then
        if not mq.TLO.Pet.Buff(spells['inspire']['name'])() and mq.TLO.Me.SpellReady(spells['inspire']['name'])() and mq.TLO.Spell(spells['inspire']['name']).Mana() < mq.TLO.Me.CurrentMana() then
            cast(spells['inspire']['name'])
        end
    end
    if is_fighting() then return end
    if mq.TLO.SpawnCount(string.format('xtarhater radius %d zradius 50', OPTS.CAMPRADIUS))() > 0 then return end
    if not mq.TLO.Me.Buff(spells['lich']['name'])() or not mq.TLO.Me.Buff(spells['flesh']['name'])() then
        use_aa(unity['name'], unity['id'])
    end
    if OPTS.BUFFPET and mq.TLO.Pet.ID() > 0 then
        for _,buff in ipairs(buffs['pet']) do
            if not mq.TLO.Pet.Buff(buff['name'])() and mq.TLO.Spell(buff['name']).StacksPet() and mq.TLO.Spell(buff['name']).Mana() < mq.TLO.Me.CurrentMana() then
                local restore_gem = nil
                if not mq.TLO.Me.Gem(buff['name'])() then
                    restore_gem = mq.TLO.Me.Gem(13)()
                    swap_spell(buff['name'], 13)
                end
                mq.delay('3s', function() return mq.TLO.Me.SpellReady(buff['name'])() end)
                cast(buff['name'])
                if restore_gem then
                    swap_spell(restore_gem, 13)
                end
            end
        end
    end
end

local function check_pet()
    debug('is_fighting=%s Pet.ID=%s spawncount=%s spellmana=%s memana=%s', is_fighting(), mq.TLO.Pet.ID(), mq.TLO.SpawnCount(string.format('xtarhater radius %d zradius 50', OPTS.CAMPRADIUS))(), mq.TLO.Spell(spells['pet']['name']).Mana(), mq.TLO.Me.CurrentMana())
    if is_fighting() or mq.TLO.Pet.ID() > 0 or mq.TLO.Me.Moving() then return end
    if mq.TLO.SpawnCount(string.format('xtarhater radius %d zradius 50', OPTS.CAMPRADIUS))() > 0 then return end
    if mq.TLO.Spell(spells['pet']['name']).Mana() > mq.TLO.Me.CurrentMana() then return end
    local restore_gem = nil
    if not mq.TLO.Me.Gem(spells['pet']['name'])() then
        restore_gem = mq.TLO.Me.Gem(13)()
        swap_spell(spells['pet']['name'], 13)
    end
    mq.delay('3s', function() return mq.TLO.Me.SpellReady(spells['pet']['name'])() end)
    cast(spells['pet']['name'])
    if restore_gem then
        swap_spell(restore_gem, 13)
    end
end

local function should_swap_dots()
    -- Only swap spells in standard spell set
    if SPELLSET_LOADED ~= 'standard' or mq.TLO.Me.Moving() then return end

    local woundsDuration = mq.TLO.Target.MyBuffDuration(spells['wounds']['name'])()
    local pyrelongDuration = mq.TLO.Target.MyBuffDuration(spells['pyrelong']['name'])()
    local fireshadowDuration = mq.TLO.Target.MyBuffDuration(spells['fireshadow']['name'])()
    if mq.TLO.Me.Gem(spells['wounds']['name'])() then
        if not OPTS.USEWOUNDS or (woundsDuration and woundsDuration > 20000) then
            if not pyrelongDuration or pyrelongDuration < 20000 then
                swap_spell(spells['pyrelong']['name'], swap_gem or 10)
            elseif not fireshadowDuration or fireshadowDuration < 20000 then
                swap_spell(spells['fireshadow']['name'], swap_gem or 10)
            end
        end
    elseif mq.TLO.Me.Gem(spells['pyrelong']['name'])() then
        if pyrelongDuration and pyrelongDuration > 20000 then
            if OPTS.USEWOUNDS and (not woundsDuration or woundsDuration < 20000) then
                swap_spell(spells['wounds']['name'], swap_gem or 10)
            elseif not fireshadowDuration or fireshadowDuration < 20000 then
                swap_spell(spells['fireshadow']['name'], swap_gem or 10)
            end
        end
    elseif mq.TLO.Me.Gem(spells['fireshadow']['name'])() then
        if fireshadowDuration and fireshadowDuration > 20000 then
            if OPTS.USEWOUNDS and (not woundsDuration or woundsDuration < 20000) then
                swap_spell(spells['wounds']['name'], swap_gem or 10)
            elseif not pyrelongDuration or pyrelongDuration < 20000 then
                swap_spell(spells['pyrelong']['name'], swap_gem or 10)
            end
        end
    else
        -- maybe we got interrupted or something and none of these are mem'd anymore? just memorize wounds again
        swap_spell(spells['wounds']['name'], swap_gem or 10)
    end

    local decayDuration = mq.TLO.Target.MyBuffDuration(spells['decay']['name'])()
    local gripDuration = mq.TLO.Target.MyBuffDuration(spells['grip']['name'])()
    if mq.TLO.Me.Gem(spells['decay']['name'])() then
        if decayDuration and decayDuration > 20000 then
            if not gripDuration or gripDuration < 20000 then
                swap_spell(spells['grip']['name'], swap_gem_dis or 11)
            end
        end
    elseif mq.TLO.Me.Gem(spells['grip']['name'])() then
        if gripDuration and gripDuration > 20000 then
            if not decayDuration or decayDuration < 20000 then
                swap_spell(spells['decay']['name'], swap_gem_dis or 11)
            end
        end
    else
        -- maybe we got interrupted or something and none of these are mem'd anymore? just memorize decay again
        swap_spell(spells['decay']['name'], swap_gem_dis or 11)
    end
end

local check_spell_timer = 0
local function check_spell_set()
    if is_fighting() or mq.TLO.Me.Moving() or am_i_dead() then return end
    if SPELLSET_LOADED ~= OPTS.SPELLSET or os.difftime(os.time(os.date("!*t")), check_spell_timer) > 30 then
        if OPTS.SPELLSET == 'standard' then
            if mq.TLO.Me.Gem(1)() ~= 'Composite Paroxysm' then swap_spell(spells['composite']['name'], 1) end
            if mq.TLO.Me.Gem(2)() ~= spells['pyreshort']['name'] then swap_spell(spells['pyreshort']['name'], 2) end
            if mq.TLO.Me.Gem(3)() ~= spells['venom']['name'] then swap_spell(spells['venom']['name'], 3) end
            if mq.TLO.Me.Gem(4)() ~= spells['magic']['name'] then swap_spell(spells['magic']['name'], 4) end
            if mq.TLO.Me.Gem(5)() ~= spells['haze']['name'] then swap_spell(spells['haze']['name'], 5) end
            if mq.TLO.Me.Gem(6)() ~= spells['grasp']['name'] then swap_spell(spells['grasp']['name'], 6) end
            if mq.TLO.Me.Gem(7)() ~= spells['leech']['name'] then swap_spell(spells['leech']['name'], 7) end
            --if mq.TLO.Me.Gem(10)() ~= spells['wounds']['name'] then swap_spell(spells['wounds']['name'], 10) end
            if mq.TLO.Me.Gem(11)() ~= spells['decay']['name'] then swap_spell(spells['decay']['name'], 11) end
            if mq.TLO.Me.Gem(13)() ~= spells['synergy']['name'] then swap_spell(spells['synergy']['name'], 13) end
            SPELLSET_LOADED = OPTS.SPELLSET
        elseif OPTS.SPELLSET == 'short' then
            if mq.TLO.Me.Gem(1)() ~= 'Composite Paroxysm' then swap_spell(spells['composite']['name'], 1) end
            if mq.TLO.Me.Gem(2)() ~= spells['pyreshort']['name'] then swap_spell(spells['pyreshort']['name'], 2) end
            if mq.TLO.Me.Gem(3)() ~= spells['venom']['name'] then swap_spell(spells['venom']['name'], 3) end
            if mq.TLO.Me.Gem(4)() ~= spells['magic']['name'] then swap_spell(spells['magic']['name'], 4) end
            if mq.TLO.Me.Gem(5)() ~= spells['haze']['name'] then swap_spell(spells['haze']['name'], 5) end
            if mq.TLO.Me.Gem(6)() ~= spells['grasp']['name'] then swap_spell(spells['grasp']['name'], 6) end
            if mq.TLO.Me.Gem(7)() ~= spells['leech']['name'] then swap_spell(spells['leech']['name'], 7) end
            if mq.TLO.Me.Gem(10)() ~= spells['swarm']['name'] then swap_spell(spells['swarm']['name'], 10) end
            if mq.TLO.Me.Gem(11)() ~= spells['decay']['name'] then swap_spell(spells['decay']['name'], 11) end
            if mq.TLO.Me.Gem(13)() ~= spells['synergy']['name'] then swap_spell(spells['synergy']['name'], 13) end
            SPELLSET_LOADED = OPTS.SPELLSET
        end
        check_spell_timer = os.time(os.date("!*t"))
        swap_gem = mq.TLO.Me.Gem(spells['wounds']['name'])() or mq.TLO.Me.Gem(spells['fireshadow']['name'])() or mq.TLO.Me.Gem(spells['pyrelong']['name'])() or 10
        swap_gem_dis = mq.TLO.Me.Gem(spells['decay']['name'])() or mq.TLO.Me.Gem(spells['grip']['name'])() or 11
    end
    if OPTS.SPELLSET == 'standard' then
        if OPTS.USEMANATAP and OPTS.USEALLIANCE and OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['shield']['name'] then swap_spell(spells['shield']['name'], 12) end
        elseif OPTS.USEMANATAP and OPTS.USEALLIANCE and not OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 12) end
        elseif OPTS.USEMANATAP and not OPTS.USEALLIANCE and not OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 12) end
        elseif OPTS.USEMANATAP and not OPTS.USEALLIANCE and OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['shield']['name'] then swap_spell(spells['shield']['name'], 12) end
        elseif not OPTS.USEMANATAP and not OPTS.USEALLIANCE and not OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['corruption']['name'] then swap_spell(spells['corruption']['name'], 12) end
        elseif not OPTS.USEMANATAP and not OPTS.USEALLIANCE and OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['shield']['name'] then swap_spell(spells['shield']['name'], 12) end
        elseif not OPTS.USEMANATAP and OPTS.USEALLIANCE and OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['shield']['name'] then swap_spell(spells['shield']['name'], 12) end
        elseif not OPTS.USEMANATAP and OPTS.USEALLIANCE and not OPTS.USEBUFFSHIELD then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 12) end
        end
        if not OPTS.USEWOUNDS then
            if mq.TLO.Me.Gem(10)() ~= spells['pyrelong']['name'] then swap_spell(spells['pyrelong']['name'], 10) end
        else
            if mq.TLO.Me.Gem(10)() ~= spells['wounds']['name'] then swap_spell(spells['wounds']['name'], 10) end
        end
    elseif OPTS.SPELLSET == 'short' then
        if OPTS.USEMANATAP and OPTS.USEALLIANCE and OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['inspire']['name'] then swap_spell(spells['inspire']['name'], 12) end
        elseif OPTS.USEMANATAP and OPTS.USEALLIANCE and not OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['venin']['name'] then swap_spell(spells['venin']['name'], 12) end
        elseif OPTS.USEMANATAP and not OPTS.USEALLIANCE and not OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['venin']['name'] then swap_spell(spells['venin']['name'], 12) end
        elseif OPTS.USEMANATAP and not OPTS.USEALLIANCE and OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['manatap']['name'] then swap_spell(spells['manatap']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['inspire']['name'] then swap_spell(spells['inspire']['name'], 12) end
        elseif not OPTS.USEMANATAP and not OPTS.USEALLIANCE and not OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['venin']['name'] then swap_spell(spells['venin']['name'], 12) end
        elseif not OPTS.USEMANATAP and not OPTS.USEALLIANCE and OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['scourge']['name'] then swap_spell(spells['scourge']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['inspire']['name'] then swap_spell(spells['inspire']['name'], 12) end
        elseif not OPTS.USEMANATAP and OPTS.USEALLIANCE and OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['inspire']['name'] then swap_spell(spells['inspire']['name'], 12) end
        elseif not OPTS.USEMANATAP and OPTS.USEALLIANCE and not OPTS.USEINSPIRE then
            if mq.TLO.Me.Gem(8)() ~= spells['ignite']['name'] then swap_spell(spells['ignite']['name'], 8) end
            if mq.TLO.Me.Gem(9)() ~= spells['alliance']['name'] then swap_spell(spells['alliance']['name'], 9) end
            if mq.TLO.Me.Gem(12)() ~= spells['venin']['name'] then swap_spell(spells['venin']['name'], 12) end
        end
    end
end

-- BEGIN UI IMPLEMENTATION

-- GUI Control variables
local open_gui = true
local should_draw_gui = true

local base_left_pane_size = 190
local left_pane_size = 190

local function draw_splitter(thickness, size0, min_size0)
    local x,y = ImGui.GetCursorPos()
    local delta = 0
    ImGui.SetCursorPosX(x + size0)

    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.6, 0.6, 0.1)
    ImGui.Button('##splitter', thickness, -1)
    ImGui.PopStyleColor(3)

    ImGui.SetItemAllowOverlap()

    if ImGui.IsItemActive() then
        delta,_ = ImGui.GetMouseDragDelta()

        if delta < min_size0 - size0 then
            delta = min_size0 - size0
        end
        if delta > 275 - size0 then
            delta = 275 - size0
        end

        size0 = size0 + delta
        left_pane_size = size0
    else
        base_left_pane_size = left_pane_size
    end
    ImGui.SetCursorPosX(x)
    ImGui.SetCursorPosY(y)
end

local function help_marker(desc)
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.Text(desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

local function draw_combo_box(label, resultvar, options, bykey)
    ImGui.Text(label)
    if ImGui.BeginCombo('##'..label, resultvar) then
        for i,j in pairs(options) do
            if bykey then
                if ImGui.Selectable(i, i == resultvar) then
                    resultvar = i
                end
            else
                if ImGui.Selectable(j, j == resultvar) then
                    resultvar = j
                end
            end
        end
        ImGui.EndCombo()
    end
    return resultvar
end

local function draw_check_box(labelText, idText, resultVar, helpText)
    resultVar,_ = ImGui.Checkbox(idText, resultVar)
    ImGui.SameLine()
    ImGui.Text(labelText)
    ImGui.SameLine()
    help_marker(helpText)
    return resultVar
end

local function draw_input_int(labelText, idText, resultVar, helpText)
    ImGui.Text(labelText)
    ImGui.SameLine()
    help_marker(helpText)
    resultVar = ImGui.InputInt(idText, resultVar)
    return resultVar
end

local function draw_input_text(labelText, idText, resultVar, helpText)
    ImGui.Text(labelText)
    ImGui.SameLine()
    help_marker(helpText)
    resultVar = ImGui.InputText(idText, resultVar)
    return resultVar
end

local function draw_left_pane_window()
    local _,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("left", left_pane_size, y-1, true) then
        OPTS.MODE = draw_combo_box('Mode', OPTS.MODE, MODES)
        set_camp()
        OPTS.SPELLSET = draw_combo_box('Spell Set', OPTS.SPELLSET, SPELLSETS, true)
        OPTS.ASSIST = draw_combo_box('Assist', OPTS.ASSIST, ASSISTS, true)
        OPTS.AUTOASSISTAT = draw_input_int('Assist %', '##assistat', OPTS.AUTOASSISTAT, 'Percent HP to assist at')
        OPTS.CAMPRADIUS = draw_input_int('Camp Radius', '##campradius', OPTS.CAMPRADIUS, 'Camp radius to assist within')
        OPTS.CHASETARGET = draw_input_text('Chase Target', '##chasetarget', OPTS.CHASETARGET, 'Chase Target')
        OPTS.CHASEDISTANCE = draw_input_int('Chase Distance', '##chasedist', OPTS.CHASEDISTANCE, 'Distance to follow chase target')
        OPTS.BURNPCT = draw_input_int('Burn Percent', '##burnpct', OPTS.BURNPCT, 'Percent health to begin burns')
        OPTS.BURNCOUNT = draw_input_int('Burn Count', '##burncnt', OPTS.BURNCOUNT, 'Trigger burns if this many mobs are on aggro')
        OPTS.STOPPCT = draw_input_int('Stop Percent', '##stoppct', OPTS.STOPPCT, 'Percent HP to stop dotting')
        OPTS.MULTICOUNT = draw_input_int('Multi DoT #', '##multidotnum', OPTS.MULTICOUNT, 'Number of mobs to rotate through when multi-dot is enabled')
    end
    ImGui.EndChild()
end

local function draw_right_pane_window()
    local x,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("right", x, y-1, true) then
        OPTS.BURNALWAYS = draw_check_box('Burn Always', '##burnalways', OPTS.BURNALWAYS, 'Always be burning')
        OPTS.BURNALLNAMED = draw_check_box('Burn Named', '##burnnamed', OPTS.BURNALLNAMED, 'Burn all named')
        OPTS.BURNPROC = draw_check_box('Burn On Proliferation', '##burnproc', OPTS.BURNPROC, 'Burn when proliferation procs')
        OPTS.DEBUFF = draw_check_box('Debuff', '##debuff', OPTS.DEBUFF, 'Debuff targets')
        OPTS.USEALLIANCE = draw_check_box('Alliance', '##alliance', OPTS.USEALLIANCE, 'Use alliance spell')
        OPTS.SWITCHWITHMA = draw_check_box('Switch With MA', '##switchwithma', OPTS.SWITCHWITHMA, 'Switch targets with MA')
        OPTS.SUMMONPET = draw_check_box('Summon Pet', '##summonpet', OPTS.SUMMONPET, 'Summon pet')
        OPTS.BUFFPET = draw_check_box('Buff Pet', '##buffpet', OPTS.BUFFPET, 'Use pet buff')
        OPTS.USEBUFFSHIELD = draw_check_box('Buff Shield', '##buffshield', OPTS.USEBUFFSHIELD, 'Keep shield buff up. Replaces corruption DoT.')
        OPTS.USEMANATAP = draw_check_box('Mana Drain', '##manadrain', OPTS.USEMANATAP, 'Use group mana drain dot. Replaces Ignite DoT.')
        OPTS.USEFD = draw_check_box('Feign Death', '##dofeign', OPTS.USEFD, 'Use FD AA\'s to reduce aggro')
        OPTS.USEREZ = draw_check_box('Use Rez', '##userez', OPTS.USEREZ, 'Use Convergence AA to rez group members')
        OPTS.USEINSPIRE = draw_check_box('Inspire Ally', '##inspire', OPTS.USEINSPIRE, 'Use Inspire Ally pet buff')
        OPTS.USEWOUNDS = draw_check_box('Use Wounds', '##usewounds', OPTS.USEWOUNDS, 'Use wounds DoT')
        OPTS.MULTIDOT = draw_check_box('Multi DoT', '##multidot', OPTS.MULTIDOT, 'DoT all mobs')
        OPTS.USEGLYPH = draw_check_box('Use Glyph', '##glyph', OPTS.USEGLYPH, 'Use Glyph of Destruction on Burn')
        OPTS.USEINTENSITY = draw_check_box('Use Intensity', '##intensity', OPTS.USEINTENSITY, 'Use Intensity of the Resolute on Burn')
    end
    ImGui.EndChild()
end

-- ImGui main function for rendering the UI window
local function necrobot_ui()
    if not open_gui then return end
    open_gui, should_draw_gui = ImGui.Begin('Necro Bot 1.0', open_gui)
    if should_draw_gui then
        if ImGui.GetWindowHeight() == 500 and ImGui.GetWindowWidth() == 500 then
            ImGui.SetWindowSize(400, 200)
        end
        if PAUSED then
            if ImGui.Button('RESUME') then
                PAUSED = false
            end
        else
            if ImGui.Button('PAUSE') then
                PAUSED = true
            end
        end
        ImGui.SameLine()
        if ImGui.Button('pre-burn') then
            mq.cmd('/nec prep')
        end
        ImGui.SameLine()
        if ImGui.Button('Save Settings') then
            save_settings()
        end
        ImGui.SameLine()
        if DEBUG then
            if ImGui.Button('Debug OFF') then
                DEBUG = false
            end
        else
            if ImGui.Button('Debug ON') then
                DEBUG = true
            end
        end
        if ImGui.BeginTabBar('##tabbar') then
            if ImGui.BeginTabItem('Settings') then
                draw_splitter(8, base_left_pane_size, 190)
                ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 6, 6)
                draw_left_pane_window()
                ImGui.PopStyleVar()
                ImGui.SameLine()
                ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 6, 6)
                draw_right_pane_window()
                ImGui.PopStyleVar()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Status') then
                ImGui.TextColored(1, 1, 0, 1, 'Status:')
                ImGui.SameLine()
                local x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                if PAUSED then
                    ImGui.TextColored(1, 0, 0, 1, 'PAUSED')
                else
                    ImGui.TextColored(0, 1, 0, 1, 'RUNNING')
                end
                ImGui.TextColored(1, 1, 0, 1, 'Mode:')
                ImGui.SameLine()
                x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                ImGui.TextColored(1, 1, 1, 1, OPTS.MODE)

                ImGui.TextColored(1, 1, 0, 1, 'Camp:')
                ImGui.SameLine()
                x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                if CAMP then
                    ImGui.TextColored(1, 1, 0, 1, string.format('X: %.02f  Y: %.02f  Z: %.02f  Rad: %d', CAMP.X, CAMP.Y, CAMP.Z, OPTS.CAMPRADIUS))
                else
                    ImGui.TextColored(1, 0, 0, 1, '--')
                end

                ImGui.TextColored(1, 1, 0, 1, 'Target:')
                ImGui.SameLine()
                x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                ImGui.TextColored(1, 0, 0, 1, string.format('%s', mq.TLO.Target()))

                ImGui.TextColored(1, 1, 0, 1, 'AM_I_DEAD:')
                ImGui.SameLine()
                x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                ImGui.TextColored(1, 0, 0, 1, string.format('%s', I_AM_DEAD))

                ImGui.TextColored(1, 1, 0, 1, 'Burning:')
                ImGui.SameLine()
                x,_ = ImGui.GetCursorPos()
                ImGui.SetCursorPosX(90)
                ImGui.TextColored(1, 0, 0, 1, string.format('%s', burn_active))
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
    ImGui.End()
end

-- END UI IMPLEMENTATION

local function show_help()
    printf('NecroBot 1.0')
    printf('Commands:\n- /nec burnnow\n- /nec pause on|1|off|0\n- /nec show|hide\n- /nec mode 0|1|2\n- /nec resetcamp\n- /nec prep\n- /nec help')
end

local function nec_bind(...)
    local args = {...}
    if not args[1] or args[1] == 'help' then
        show_help()
    elseif args[1]:lower() == 'burnnow' then
        BURN_NOW = true
    elseif args[1] == 'pause' then
        if not args[2] then
            PAUSED = not PAUSED
        else
            if args[2] == 'on' or args[2] == '1' then
                PAUSED = true
            elseif args[2] == 'off' or args[2] == '0' then
                PAUSED = false
            end
        end
    elseif args[1] == 'show' then
        open_gui = true
    elseif args[1] == 'hide' then
        open_gui = false
    elseif args[1] == 'mode' then
        if args[2] == '0' then
            OPTS.MODE = MODES[1]
            set_camp()
        elseif args[2] == '1' then
            OPTS.MODE = MODES[2]
            set_camp()
        elseif args[2] == '2' then
            OPTS.MODE = MODES[3]
            set_camp()
        end
    elseif args[1] == 'prep' then
        pre_pop_burns()
    elseif args[1] == 'resetcamp' then
        set_camp(true)
    else
        -- some other argument, show or modify a setting
        local opt = args[1]:upper()
        local new_value = args[2]
        if args[2] then
            if opt == 'SPELLSET' then
                if SPELLSETS[new_value] then
                    printf('Setting %s to: %s', opt, new_value)
                    OPTS[opt] = new_value
                end
            elseif opt == 'ASSIST' then
                if ASSISTS[new_value] then
                    printf('Setting %s to: %s', opt, new_value)
                    OPTS[opt] = new_value
                end
            elseif type(OPTS[opt]) == 'boolean' then
                if args[2] == '0' or args[2] == 'off' then
                    printf('Setting %s to: false', opt)
                    OPTS[opt] = false
                elseif args[2] == '1' or args[2] == 'on' then
                    printf('Setting %s to: true', opt)
                    OPTS[opt] = true
                end
            elseif type(OPTS[opt]) == 'number' then
                if tonumber(new_value) then
                    printf('Setting %s to: %s', opt, tonumber(new_value))
                    OPTS[opt] = tonumber(new_value)
                end
            else
                printf('Unsupported command line option: %s %s', opt, new_value)
            end
        else
            if OPTS[opt] ~= nil then
                printf('%s: %s', opt, OPTS[opt])
            else
                printf('Unrecognized option: %s', opt)
            end
        end
    end
end
mq.bind('/nec', nec_bind)
mq.bind('/necro', nec_bind)

local function event_dead()
    printf('necro down!')
    I_AM_DEAD = true
end
mq.event('event_dead_released', '#*#Returning to Bind Location#*#', event_dead)
mq.event('event_dead', 'You died.', event_dead)
mq.event('event_dead_slain', 'You have been slain by#*#', event_dead)

mq.imgui.init('Necro Bot 1.0', necrobot_ui)

load_settings()

mq.TLO.Lua.Turbo(500)
mq.cmd('/plugin melee unload noauto')
get_necro_count()

local debug_timer = 0
local nec_count_timer = 0
-- Main Loop
while true do
    if DEBUG and os.difftime(os.time(os.date("!*t")), debug_timer) > 3 then
        debug('main loop: PAUSED=%s, Me.Invis=%s', PAUSED, mq.TLO.Me.Invis())
        debug_timer = os.time(os.date("!*t"))
    end
    if OPTS.USEALLIANCE and os.difftime(os.time(os.date("!*t")), nec_count_timer) > 60 then
        get_necro_count()
        nec_count_timer = os.time(os.date("!*t"))
    end
    -- Process death events
    mq.doevents()
    -- do active combat assist things when not paused and not invis
    if not PAUSED and not mq.TLO.Me.Invis() and not mq.TLO.Me.Feigning() then
        -- keep cursor clear for spell swaps and such
        if mq.TLO.Cursor() then
            mq.cmd('/autoinventory')
        end
        --prune_dot_targets()
        -- ensure correct spells are loaded based on selected spell set
        -- currently only checks at startup or when selection changes
        check_spell_set()
        -- check whether we need to return to camp
        check_camp()
        -- check whether we need to go chasing after the chase target
        check_chase()
        -- check we have the correct target to attack
        --if OPTS.MULTIDOT then
        --    check_target_multi()
        --else
        check_target()
        --end
        -- if we should be assisting but aren't in los, try to be?
        check_los()
        -- begin actual combat stuff
        send_pet()
        try_debuff_target()
        if not cycle_dots() then
            -- if we found no DoT to cast this loop, check if we should swap
            should_swap_dots()
        end
        -- pop a bunch of burn stuff if burn conditions are met
        try_burn()
        -- try not to run OOM
        check_aggro()
        check_mana()
        check_buffs()
        check_pet()
        check_rez()
        rest()
        mq.delay(1)
    elseif not PAUSED and (mq.TLO.Me.Invis() or mq.TLO.Me.Feigning()) then
        -- stay in camp or stay chasing chase target if not paused but invis
        if mq.TLO.Pet() and mq.TLO.Pet.Target() and mq.TLO.Pet.Target.ID() > 0 then mq.cmd('/pet back') end
        if OPTS.MODE == 'assist' and should_assist() then mq.cmd('/makemevis') end
        check_camp()
        check_chase()
        rest()
        mq.delay(50)
    else
        if mq.TLO.Pet() and mq.TLO.Pet.Target() and mq.TLO.Pet.Target.ID() > 0 then mq.cmd('/pet back') end
        -- paused, spin
        mq.delay(500)
    end
end
