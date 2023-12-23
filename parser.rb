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
      mob_data[planet] = []
      files = Dir.glob(File.join(creature_base, planet, '*.lua')).reject { |f| f.end_with?('serverobjects.lua') }
      puts "#{planet} (#{files.size}): "
      files.each do |file|
        next if file.end_with?('serverobjects.lua')
        mob_data[planet] << convert(parse_lua(file))
        print '.'
      end
      puts
    end
    mob_data
  end

  def creature_base
    File.join(@base, 'MMOCoreORB/bin/scripts/mobile')
  end

  private

  def merge(*a)
    x = []
    a.each { |z| x << z }
    x
  end

  def parse_lua(file)
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

  def convert(mob)
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
      output[:ham] = (mob[:baseHAM] + mob[:baseHAMmax]) / 2
      output[:xp] = mob[:baseXp]
      output[:armor] = mob[:armor]
      output[:kinetic_resist] = parse_resist(mob[:resists][0])
      output[:energy_resist] = parse_resist(mob[:resists][1])
      output.each { |k, v| output[k] = v.to_s if v.is_a?(SwgConstant) }
      output
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
data = parser.mob_data
npcs = {}
creatures = {}
data.each do |planet, mobs|
  npcs[planet], creatures[planet] = mobs.partition { |m| m[:type] == 'MOB_NPC' }
end
FileUtils.mkdir_p('data')
File.write(File.join('data', 'creatures.json'), JSON.pretty_generate(creatures))
File.write(File.join('data', 'npcs.json'), JSON.pretty_generate(npcs))
