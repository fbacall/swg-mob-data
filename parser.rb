require 'json'
require 'fileutils'

class Parser
  PLANETS = %w(corellia dantooine dathomir endor lok naboo rori talus tatooine yavin4)

  def initialize(base)
    @base = base
  end

  def i18n
    return @i18n if @i18n
    strings = File.read(string_base)
    @i18n = {}
    prefixes = Hash[strings.scan(/stringFiles\[(\d+)\]\s*=\s*new\s*StringFile\("([^"]+)"\)/)]
    strings.scan(/stringFiles\[(\d+)\]\.addEntry\("([^"]+)", "([^"]+)"\)\;/).each do |match|
      prefix = prefixes[match[0]]
      raise "Missing stringFile index: #{match[0]}" unless prefix
      @i18n["@#{prefix}:#{match[1]}"] = match[2]
    end
    @i18n
  end

  def mob_data
    mob_data = {}
    PLANETS.each do |planet|
      files = Dir.glob(File.join(creature_base, planet, '*.lua')).reject { |f| f.end_with?('serverobjects.lua') }
      puts "#{planet} (#{files.size}): "
      files.each do |file|
        next if file.end_with?('serverobjects.lua')
        mob = convert_mob(parse_mob_lua(file))
        next if mob.nil?
        raise "Mob ID collision #{mob[:id]}" if mob_data[mob[:id]]
        mob_data[mob[:id]] = mob
        print '.'
      end
      puts
    end
    mob_data
  end

  def mission_data
    mission_data = {}
    PLANETS.each do |planet|
      file = File.join(mission_base, "#{planet}_destroy_missions.lua")
      mission_data[planet] = parse_mission_lua(file)
    end
    mission_data.each do |planet, lairs|
      lairs.map! do |lair|
        convert_mission(lair.merge(mobs: lair_data[lair[:lairTemplateName]][:mobs]))
      end
    end
    mission_data
  end

  def lair_data
    return @lair_data if @lair_data
    @lair_data = {}
    (PLANETS + ['global']).each do |loc|
      ['creature_lair', 'npc_theater', 'creature_dynamic', 'npc_dynamic'].each do |type|
        files = Dir.glob(File.join(lair_base, type, loc, "*.lua"))
        puts "#{loc} #{type} (#{files.size}): "
        files.each do |file|
          lair = parse_lair_lua(file)
          raise "Lair ID collision #{lair[:id]}" if @lair_data[lair[:id]]
          @lair_data[lair[:id]] = lair
          print '.'
        end
        puts
      end
    end
    @lair_data
  end

  def spawn_data
    return @spawn_data if @spawn_data
    @spawn_data = {}
    PLANETS.each do |planet|
      files = Dir.glob(File.join(spawn_base, planet, '*.lua'))
      puts "#{planet} (#{files.size}): "
      files.each do |file|
        spawn = convert_spawns(parse_spawn_lua(file))
        warn "Spawn id collision #{spawn[:id]}" if @spawn_data[spawn[:id]]
        @spawn_data[spawn[:id]] = spawn.merge(mobs: spawn[:lairs].map { |l| lair_data[l[:id]][:mobs].map(&:first) }.flatten )
        print '.'
      end
      puts
    end
    @spawn_data
  end

  def region_data
    region_data = {}
    PLANETS.each do |planet|
      file = File.join(region_base, "#{planet}_regions.lua")
      region_data[planet] = {}
      convert_regions(parse_region_lua(file)).each do |region|
        raise "Region ID collision #{region[:id]}" if region_data[planet][region[:id]]
        region_data[planet][region[:id]] = region.merge(mobs: region[:spawns].map { |s| spawn_data[s][:mobs] }.flatten )
      end
      print '.'
    end

    region_data
  end

  def static_spawn_data
    static_spawn_data = {}
    (Dir.glob(File.join(static_spawn_base, '*.lua')) + Dir.glob(File.join(city_spawn_base, '*.lua'))).each do |file|
      next if file.end_with?('/city.lua')
      parse_static_spawn_lua(file).each do |static_spawn|
        planet = static_spawn.delete(:planet)
        static_spawn_data[planet] ||= {}
        mob = static_spawn.delete(:mob)
        static_spawn_data[planet][mob] ||= []
        static_spawn_data[planet][mob] << [static_spawn[:x], static_spawn[:y]]
      end
      print '.'
    end

    static_spawn_data
  end

  def string_base
    File.join(@base, 'MMOCoreORB', 'doc', 'ConversationEditor', 'stringfiles.js')
  end

  def creature_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'mobile')
  end

  def mission_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'mobile', 'spawn', 'destroy_mission')
  end

  def lair_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'mobile', 'lair')
  end

  def region_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'managers', 'planet')
  end

  def spawn_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'mobile', 'spawn')
  end

  def static_spawn_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'screenplays', 'static_spawns')
  end

  def city_spawn_base
    File.join(@base, 'MMOCoreORB', 'bin', 'scripts', 'screenplays', 'cities')
  end

  private

  def merge(*a)
    x = []
    a.each { |z| x << z }
    x
  end

  def parse_mob_lua(file)
    data = File.read(file)
    strip_comments(data)
    data.gsub!('{', '[') # Array open
    data.gsub!('}', ']') # Array close
    data.gsub!(';', ',') # Some lines end in semi-colon instead of comma for some reason
    data.gsub!(/\s*=\s*/, ': ') # = to :
    data.sub!(/Creature:new \[/, '{') # Definition opening
    data.sub!(/\]\s*CreatureTemplates.*/, '}') # Definition close
    data.sub!(/socialGroup:\s*(.+),/, 'socialGroup: [\1],') # Wrap socialGroup strings as an array
    data.sub!(/:\s*\./, ': 0.') # Floats without leading 0

    begin
      # Parse creature name from start of file
      match_data = data.match(/([a-zA-Z0-9_-]+)\s*:\s*{/)
      raise "Couldn't match creature name" if match_data.nil?
      id = match_data[1]
      data.sub!(match_data[0], '{')
      d = eval(data)
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      raise e
    end

    d[:id] = id # Merge parsed id back in
    d
  end

  def parse_mission_lua(file)
    data = File.read(file)
    strip_comments(data)
    data.gsub!('{', '[') # Array open
    data.gsub!('}', ']') # Array close
    data.gsub!(';', ',') # Some lines end in semi-colon instead of comma for some reason
    data.gsub!(/\s*=\s*/, ': ') # = to :
    data.sub!(/.+_missions\s*:\s*\[/, '')
    data.sub!(/\s*addDestroyMissionGroup.*/, '')
    data.sub!(/\s*lairSpawns\s*:\s*/, '')
    data.sub!(/\s*minLevelCeiling\s*:\s*\d*\s*,?/, '[')
    data.sub!(/\s*addDestroyMissionGroup.*/, '')

    data.sub!(/:\s*\./, ': 0.') # Floats without leading 0

    begin
      d = eval(data)
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      raise e
    end

    d.flatten
  end

  def parse_lair_lua(file)
    data = File.read(file)
    i = data.index('mobile')
    raise 'No mobile data' unless i
    open = 0
    buffer = ''
    while true
      case data[i]
      when '{'
        open += 1
        buffer << '['
      when '}'
        open -= 1
        buffer << ']'
        break if open.zero?
      when nil
        break
      else
        buffer << data[i] unless open.zero?
      end
      i += 1
    end

    begin
      d = eval(buffer)
      # Parse creature name from start of file
      match_data = data.match(/([a-zA-Z0-9_-]+)\s*=\s*Lair:new\s*{/)
      raise "Couldn't match lair name" if match_data.nil?
      id = match_data[1]
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      STDERR.puts 'buffer:'
      STDERR.puts buffer
      raise e
    end

    { id: id, mobs: d }
  end

  def parse_spawn_lua(file)
    data = File.read(file)
    strip_comments(data)
    data.gsub!('{', '[') # Array open
    data.gsub!('}', ']') # Array close
    data.gsub!(';', ',') # Some lines end in semi-colon instead of comma for some reason
    data.gsub!(/\s*=\s*/, ': ') # = to :
    data.sub!(/\s*lairSpawns\s*:\s*\[/, '[')
    data.sub!(/\s*addSpawnGroup.*/, '')

    begin
      # Parse spawn name from start of file
      match_data = data.match(/([a-zA-Z0-9_-]+)\s*:\s*\[/)
      raise "Couldn't match spawn name" if match_data.nil?
      id = match_data[1]
      data.sub!(match_data[0], '[')
      d = eval(data)
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      raise e
    end

    { id: id, lairs: d.flatten }
  end

  def parse_region_lua(file)
    data = File.read(file)
    strip_comments(data)
    data.gsub!('{', '[') # Array open
    data.gsub!('}', ']') # Array close
    data.gsub!(';', ',') # Some lines end in semi-colon instead of comma for some reason
    data.gsub!(/\s*=\s*/, ': ') # = to :
    data.sub!(/.+_regions\s*:\s*\[/, '[')
    data.sub!(/\s*require.*/, '')

    begin
      d = eval(data)
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      raise e
    end

    d
  end

  def parse_static_spawn_lua(file)
    data = File.read(file)
    strip_comments(data)
    planet = nil
    m = data.match(/planet\s*=\s*"([^"]+)"/)
    planet = m[1] if m
    data.gsub!('self.planet', "\"#{planet}\"") if planet
    data.gsub!('math.rad', '')
    # explicit spawnMobiles calls
    spawns = data.scan(/spawnMobile\(.+/).map do |s|
      s.sub!('spawnMobile(', '[')
      s.strip!
      s.sub!(/\)$/, ']')
      s.sub!(/\)--.+/, ']')
      next if s.include?(', mob')
      begin
        d = eval(s)
      rescue Exception => e
        STDERR.puts "!!! ERROR parsing #{file}"
        STDERR.puts s
        raise e
      end
      { planet: d[0], mob: d[1], x: d[3], y: d[5] }
    end.compact

    # from array e.g. mobiles = {}
    i = data.index('mobiles = {')
    if i && planet
      open = 0
      buffer = ''
      comment = false
      while true
        case data[i]
        when '{'
          open += 1
          buffer << '['
        when '}'
          open -= 1
          buffer << ']'
          break if open.zero?
        when nil
          break
        else
          if data[i] == '-' && data[i+1] == '-'
            comment = true
          elsif comment && data[i] == "\n"
            comment = false
          elsif !comment
            buffer << data[i] unless open.zero?
          end
        end
        i += 1
      end

      begin
        d = eval(buffer)
      rescue Exception => e
        STDERR.puts "!!! ERROR parsing #{file}"
        STDERR.puts data
        STDERR.puts 'buffer:'
        STDERR.puts buffer
        raise e
      end

      spawns += d.map do |s|
        { planet: planet, mob: s[0], x: s[2], y: s[4] }
      end
    end

    spawns.uniq
  end

  def convert(output)
    output.each do |k, v|
      output[k] = v.to_s if v.is_a?(SwgConstant)
      output[k] = output[k].strip if output[k].is_a?(String)
    end
    output
  end

  def convert_mob(mob)
    begin
      return nil unless mob[:pvpBitmask].to_ary.any? { |r| r.to_s == 'ATTACKABLE' }
      output = {}
      output[:id] = mob[:id]
      output[:name] = mob[:customName] || i18n.fetch(mob[:objectName])
      output[:type] = mob[:mobType]
      output[:level] = mob[:level]
      output[:meat] = mob[:meatAmount] unless mob[:meatAmount] == 0
      output[:meat_type] = mob[:meatType] unless mob[:meatType].nil? || mob[:meatType] == ''
      output[:hide] = mob[:hideAmount] unless mob[:hideAmount] == 0
      output[:hide_type] = mob[:hideType] unless mob[:hideType].nil? || mob[:hideType] == ''
      output[:bone] = mob[:boneAmount] unless mob[:boneAmount] == 0
      output[:bone_type] = mob[:boneType] unless mob[:boneType].nil? || mob[:boneType] == ''
      output[:milk] = mob[:milk] unless mob[:milk] == 0
      output[:milk_type] = mob[:milkType] unless mob[:milkType].nil?
      output[:attacks] = ((mob[:primaryAttacks] || []).to_ary.flatten | (mob[:secondaryAttacks] || []).to_ary.flatten).reject { |i| i.nil? || i == '' }
      output[:attacks] << 'ranged' if mob[:primaryWeapon]&.include?('object/weapon/ranged') || mob[:secondaryWeapon]&.include?('object/weapon/ranged')
      output[:ham] = (mob[:baseHAM] + mob[:baseHAMmax]) / 2
      output[:xp] = mob[:baseXp]
      output[:armor] = mob[:armor]
      output[:kinetic_resist] = parse_resist(mob[:resists][0])
      output[:energy_resist] = parse_resist(mob[:resists][1])
      convert(output)
    rescue Exception => e
      STDERR.puts "!!! ERROR converting"
      STDERR.puts mob.inspect
      raise e
    end
  end

  def convert_mission(mission)
    begin
      output = {}
      output[:id] = mission[:lairTemplateName]
      output[:name] = i18n.fetch("@#{lair_n}:#{mission[:lairTemplateName]}")
      output[:min_cl] = mission[:minDifficulty]
      output[:max_cl] = mission[:maxDifficulty]
      output[:size] = mission[:size]
      output[:mobs] = mission[:mobs].map(&:first)
      convert(output)
    rescue Exception => e
      STDERR.puts "!!! ERROR converting"
      STDERR.puts mission.inspect
      raise e
    end
  end

  def convert_spawns(spawn)
    s = []
    total = 0
    spawn[:lairs].each do |lair|
      begin
        output = {}
        output[:id] = lair[:lairTemplateName]
        output[:min_cl] = lair[:minDifficulty]
        output[:max_cl] = lair[:maxDifficulty]
        output[:weighting] = lair[:weighting]
        total += output[:weighting]
        s << convert(output)
      rescue Exception => e
        STDERR.puts "!!! ERROR converting"
        STDERR.puts lair.inspect
        raise e
      end
    end
    s.each { |spawn| spawn[:chance] = spawn[:weighting].to_f / total }
    spawn[:lairs] = s
    spawn
  end

  def convert_regions(regions)
    regions.map do |region|
      next unless region[4].to_ary.any? { |r| r.to_s == 'SPAWNAREA' }
      r = {}
      r[:id] = region[0]
      x, y = region[1], region[2]
      shape = region[3]
      r[:spawns] = region[5]
      r[:shape] = [shape.shift.to_s.downcase, x, y, *shape]
      r
    end.compact
  end

  def parse_resist(resist)
    return 'Vul' if resist == -1
    return 0 if resist == 0
    resist -= 100 if resist > 100
    resist
  end

  # Handle unrecognized variables and constants and treat them like a symbol
  class SwgConstant
    def initialize(symbol)
      @symbol = symbol
    end

    def +(other)
      if other.is_a?(Array)
        [@symbol] + other
      else
        [@symbol, other]
      end
    end

    def to_s
      @symbol.to_s
    end

    def to_ary
      [@symbol]
    end
  end

  def strip_comments(data)
    data.gsub!(/\s*\-\-\[\[.+\]\]/m, "\n") # Block comments
    data.gsub!(/\s*\-\-[^\n]*\n/,"\n") # Comments
    data.gsub!(/,\s*\-\-[^\n]*\n/,",\n") # Comments following ,
  end

  def getRandomNumber(n)
    (n.to_f / 2)
  end

  def method_missing(symbol, *args)
    SwgConstant.new(symbol)
  end

  def self.const_missing(symbol, *args)
    SwgConstant.new(symbol)
  end
end

parser = Parser.new(ARGV[0])
mob_data = parser.mob_data
mission_data = parser.mission_data
region_data = parser.region_data
static_spawn_data = parser.static_spawn_data

FileUtils.mkdir_p('data')
File.write(File.join('data', "mobs.json"), JSON.pretty_generate(mob_data))
File.write(File.join('data', "missions.json"), JSON.pretty_generate(mission_data))
File.write(File.join('data', "regions.json"), JSON.pretty_generate(region_data))
File.write(File.join('data', "static_spawns.json"), JSON.pretty_generate(static_spawn_data))
