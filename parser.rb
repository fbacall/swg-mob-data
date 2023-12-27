require 'json'
require 'fileutils'

class Parser
  PLANETS = %w(corellia dantooine dathomir endor lok naboo rori talus tatooine yavin4)

  def initialize(base)
    @base = base
  end

  def mob_data
    mob_data = {}
    PLANETS.each do |planet|
      mob_data[planet] = {}
      files = Dir.glob(File.join(creature_base, planet, '*.lua')).reject { |f| f.end_with?('serverobjects.lua') }
      puts "#{planet} (#{files.size}): "
      files.each do |file|
        next if file.end_with?('serverobjects.lua')
        mob = convert_mob(parse_mob_lua(file))
        mob_data[planet][mob[:name]] = mob
        print '.'
      end
      puts
    end
    mob_data
  end

  def mission_data
    mission_data = {}
    PLANETS.each do |planet|
      mission_data[planet] = []
      file = File.join(mission_base, "#{planet}_destroy_missions.lua")
      puts file
      mission_data[planet] = parse_mission_lua(file)
    end
    mission_data.each do |planet, lairs|
      lairs.each_key do |lair|
        lairs[lair].merge!(mobs: lair_data(lair, planet))
      end
    end
    mission_data
  end

  def lair_data(lair, planet)
    path = File.join(lair_base, 'creature_lair', planet, "#{lair}.lua")
    path = File.join(lair_base, 'npc_theater', planet, "#{lair}.lua") unless File.exist?(path)
    path = File.join(lair_base, 'creature_dynamic', planet, "#{lair}.lua") unless File.exist?(path)
    path = File.join(lair_base, 'npc_dynamic', planet, "#{lair}.lua") unless File.exist?(path)
    unless File.exist?(path)
      STDERR.puts "Can't find path for lair: #{lair}, skipping!"
      return []
    end

    parse_lair_lua(path)
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

  private

  def merge(*a)
    x = []
    a.each { |z| x << z }
    x
  end

  def parse_mob_lua(file)
    data = File.read(file)
    data.gsub!(/\s*\-\-[^\n]+\n/,"\n") # Comments
    data.gsub!(/,\s*\-\-[^\n]+\n/,",\n") # Comments following ,
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
      name = match_data[1]
      data.sub!(match_data[0], '{')
      d = eval(data)
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      raise e
    end

    d[:name] = name # Merge parsed name back in
    d
  end

  def parse_mission_lua(file)
    data = File.read(file)
    data.gsub!(/\s*\-\-[^\n]+\n/,"\n") # Comments
    data.gsub!(/,\s*\-\-[^\n]+\n/,",\n") # Comments following ,
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

    h = {}
    d.flatten.each do |mission|
      h[mission.delete(:lairTemplateName)] = mission
    end
    h
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
    rescue Exception => e
      STDERR.puts "!!! ERROR parsing #{file}"
      STDERR.puts data
      STDERR.puts 'buffer:'
      STDERR.puts buffer
      raise e
    end

    d
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
      output = {}
      output[:name] = mob[:name]
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
mission_data.each do |planet, missions|
  planet_mobs = mob_data[planet]
  missions.each_value do |mission|
    (mission[:mobs] || []).each do |mission_mob|
      mob_name = mission_mob[0]
      mob = planet_mobs[mob_name]
      unless mob
        puts "Missing #{mob_name} from #{planet}"
        Parser::PLANETS.each do |other_planet|
          if mob_data[other_planet].key?(mob_name)
            mob = mob_data[other_planet][mob_name]
            puts "...found on #{other_planet}"
          end
        end
      end
      if mission[:minDifficulty]
        mob[:mission_min] ||= 9999
        mob[:mission_min] = mission[:minDifficulty] if mission[:minDifficulty] < mob[:mission_min]
      end

      if mission[:maxDifficulty]
        mob[:mission_max] ||= 9999
        mob[:mission_max] = mission[:maxDifficulty] if mission[:maxDifficulty] < mob[:mission_max]
      end
    end
  end
end

TYPES = {
  'MOB_HERBIVORE' => 'creatures',
  'MOB_CARNIVORE' => 'creatures',
  'MOB_NPC' => 'npcs',
  'MOB_DROID' => 'npcs',
  'MOB_ANDROID' => 'npcs'
}

categorized = {}
mob_data.each do |planet, mobs|
  mobs.values.sort { |a, b| a[:name] <=> b[:name] }.each do |mob|
    category = TYPES[mob[:type]]
    categorized[category] ||= {}
    categorized[category][planet] ||= []
    categorized[category][planet] << mob
  end
end
FileUtils.mkdir_p('data')
categorized.each do |category, mobs|
  File.write(File.join('data', "#{category}.json"), JSON.pretty_generate(mobs))
end
