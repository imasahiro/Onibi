# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Layout/IndentationWidth, Layout/EmptyLineBetweenDefs, Layout/IndentationConsistency, Style/NumericLiterals
# The range tables come from MRI Unicode property matching at development time.

module Onibi
  # Matches Unicode script and block ranges used by property dispatch.
  module UnicodePropertyScripts
UNICODE_LATIN_RANGES = [[65, 90], [97, 122], [170, 170], [186, 186], [192, 214], [216, 246], [248, 696], [736, 740], [7424, 7461], [7468, 7516], [7522, 7525], [7531, 7543], [7545, 7614], [7680, 7935], [8305, 8305], [8319, 8319], [8336, 8348], [8490, 8491], [8498, 8498], [8526, 8526], [8544, 8584], [11360, 11391], [42786, 42887], [42891, 42972], [42993, 43007], [43824, 43866], [43868, 43876], [43878, 43881], [64256, 64262], [65313, 65338], [65345, 65370], [67456, 67461], [67463, 67504], [67506, 67514], [122624, 122654], [122661, 122666]].freeze
    UNICODE_GREEK_RANGES = [[880, 883], [885, 887], [890, 893], [895, 895], [900, 900], [902, 902], [904, 906], [908, 908], [910, 929], [931, 993], [1008, 1023], [7462, 7466], [7517, 7521], [7526, 7530], [7615, 7615], [7936, 7957], [7960, 7965], [7968, 8005], [8008, 8013], [8016, 8023], [8025, 8025], [8027, 8027], [8029, 8029], [8031, 8061], [8064, 8116], [8118, 8132], [8134, 8147], [8150, 8155], [8157, 8175], [8178, 8180], [8182, 8190], [8486, 8486], [43877, 43877], [65856, 65934], [65952, 65952], [119296, 119365]].freeze
    UNICODE_CYRILLIC_RANGES = [[1024, 1156], [1159, 1327], [7296, 7306], [7467, 7467], [7544, 7544], [11744, 11775], [42560, 42655], [65070, 65071], [122928, 122989], [123023, 123023]].freeze
    UNICODE_ARABIC_RANGES = [[1536, 1540], [1542, 1547], [1549, 1562], [1564, 1566], [1568, 1599], [1601, 1610], [1622, 1647], [1649, 1756], [1758, 1791], [1872, 1919], [2160, 2193], [2199, 2273], [2275, 2303], [64336, 64829], [64832, 64975], [65008, 65023], [65136, 65140], [65142, 65276], [69216, 69246], [69314, 69319], [69328, 69336], [69370, 69375], [126464, 126467], [126469, 126495], [126497, 126498], [126500, 126500], [126503, 126503], [126505, 126514], [126516, 126519], [126521, 126521], [126523, 126523], [126530, 126530], [126535, 126535], [126537, 126537], [126539, 126539], [126541, 126543], [126545, 126546], [126548, 126548], [126551, 126551], [126553, 126553], [126555, 126555], [126557, 126557], [126559, 126559], [126561, 126562], [126564, 126564], [126567, 126570], [126572, 126578], [126580, 126583], [126585, 126588], [126590, 126590], [126592, 126601], [126603, 126619], [126625, 126627], [126629, 126633], [126635, 126651], [126704, 126705]].freeze
    UNICODE_HAN_RANGES = [[11904, 11929], [11931, 12019], [12032, 12245], [12293, 12293], [12295, 12295], [12321, 12329], [12344, 12347], [13312, 19903], [19968, 40959], [63744, 64109], [64112, 64217], [94178, 94179], [94192, 94198], [131072, 173791], [173824, 178205], [178208, 183981], [183984, 191456], [191472, 192093], [194560, 195101], [196608, 201546], [201552, 210041]].freeze
    UNICODE_HIRAGANA_RANGES = [[12353, 12438], [12445, 12447], [110593, 110879], [110898, 110898], [110928, 110930], [127488, 127488]].freeze
    UNICODE_KATAKANA_RANGES = [[12449, 12538], [12541, 12543], [12784, 12799], [13008, 13054], [13056, 13143], [65382, 65391], [65393, 65437], [110576, 110579], [110581, 110587], [110589, 110590], [110592, 110592], [110880, 110882], [110933, 110933], [110948, 110951]].freeze

    def script_match?(character, ranges)
      codepoint = character.codepoints.first
      ranges.any? { |range| range[0] <= codepoint && codepoint <= range[1] }
    end
    def ascii?(character)
      character.codepoints.first <= 127
    end

    def any?(_character)
      true
    end

    def han?(character)
      script_match?(character, UNICODE_HAN_RANGES)
    end

    def hiragana?(character)
      script_match?(character, UNICODE_HIRAGANA_RANGES)
    end

    def katakana?(character)
      script_match?(character, UNICODE_KATAKANA_RANGES)
    end

    def latin?(character)
      script_match?(character, UNICODE_LATIN_RANGES)
    end

    def greek?(character)
      script_match?(character, UNICODE_GREEK_RANGES)
    end

    def cyrillic?(character)
      script_match?(character, UNICODE_CYRILLIC_RANGES)
    end

    def arabic?(character)
      script_match?(character, UNICODE_ARABIC_RANGES)
    end
  end
end

# rubocop:enable Layout/LineLength, Layout/IndentationWidth, Layout/EmptyLineBetweenDefs, Layout/IndentationConsistency, Style/NumericLiterals
