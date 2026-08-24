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
    # Generated from MRI's Onigmo \p{Emoji} ctype table.
    UNICODE_EMOJI_RANGES = [[35, 35], [42, 42], [48, 57], [169, 169], [174, 174], [8252, 8252], [8265, 8265], [8482, 8482], [8505, 8505], [8596, 8601], [8617, 8618], [8986, 8987], [9000, 9000], [9167, 9167], [9193, 9203], [9208, 9210], [9410, 9410], [9642, 9643], [9654, 9654], [9664, 9664], [9723, 9726], [9728, 9732], [9742, 9742], [9745, 9745], [9748, 9749], [9752, 9752], [9757, 9757], [9760, 9760], [9762, 9763], [9766, 9766], [9770, 9770], [9774, 9775], [9784, 9786], [9792, 9792], [9794, 9794], [9800, 9811], [9823, 9824], [9827, 9827], [9829, 9830], [9832, 9832], [9851, 9851], [9854, 9855], [9874, 9879], [9881, 9881], [9883, 9884], [9888, 9889], [9895, 9895], [9898, 9899], [9904, 9905], [9917, 9918], [9924, 9925], [9928, 9928], [9934, 9935], [9937, 9937], [9939, 9940], [9961, 9962], [9968, 9973], [9975, 9978], [9981, 9981], [9986, 9986], [9989, 9989], [9992, 9997], [9999, 9999], [10002, 10002], [10004, 10004], [10006, 10006], [10013, 10013], [10017, 10017], [10024, 10024], [10035, 10036], [10052, 10052], [10055, 10055], [10060, 10060], [10062, 10062], [10067, 10069], [10071, 10071], [10083, 10084], [10133, 10135], [10145, 10145], [10160, 10160], [10175, 10175], [10548, 10549], [11013, 11015], [11035, 11036], [11088, 11088], [11093, 11093], [12336, 12336], [12349, 12349], [12951, 12951], [12953, 12953], [126980, 126980], [127183, 127183], [127344, 127345], [127358, 127359], [127374, 127374], [127377, 127386], [127462, 127487], [127489, 127490], [127514, 127514], [127535, 127535], [127538, 127546], [127568, 127569], [127744, 127777], [127780, 127891], [127894, 127895], [127897, 127899], [127902, 127984], [127987, 127989], [127991, 128253], [128255, 128317], [128329, 128334], [128336, 128359], [128367, 128368], [128371, 128378], [128391, 128391], [128394, 128397], [128400, 128400], [128405, 128406], [128420, 128421], [128424, 128424], [128433, 128434], [128444, 128444], [128450, 128452], [128465, 128467], [128476, 128478], [128481, 128481], [128483, 128483], [128488, 128488], [128495, 128495], [128499, 128499], [128506, 128591], [128640, 128709], [128715, 128722], [128725, 128728], [128732, 128741], [128745, 128745], [128747, 128748], [128752, 128752], [128755, 128764], [128992, 129003], [129008, 129008], [129292, 129338], [129340, 129349], [129351, 129535], [129648, 129660], [129664, 129674], [129678, 129734], [129736, 129736], [129741, 129756], [129759, 129770], [129775, 129784]].freeze
    # Generated from MRI's Onigmo \p{Emoji_Presentation} ctype table.
    UNICODE_EMOJI_PRESENTATION_RANGES = [[8986, 8987], [9193, 9196], [9200, 9200], [9203, 9203], [9725, 9726], [9748, 9749], [9800, 9811], [9855, 9855], [9875, 9875], [9889, 9889], [9898, 9899], [9917, 9918], [9924, 9925], [9934, 9934], [9940, 9940], [9962, 9962], [9970, 9971], [9973, 9973], [9978, 9978], [9981, 9981], [9989, 9989], [9994, 9995], [10024, 10024], [10060, 10060], [10062, 10062], [10067, 10069], [10071, 10071], [10133, 10135], [10160, 10160], [10175, 10175], [11035, 11036], [11088, 11088], [11093, 11093], [126980, 126980], [127183, 127183], [127374, 127374], [127377, 127386], [127462, 127487], [127489, 127489], [127514, 127514], [127535, 127535], [127538, 127542], [127544, 127546], [127568, 127569], [127744, 127776], [127789, 127797], [127799, 127868], [127870, 127891], [127904, 127946], [127951, 127955], [127968, 127984], [127988, 127988], [127992, 128062], [128064, 128064], [128066, 128252], [128255, 128317], [128331, 128334], [128336, 128359], [128378, 128378], [128405, 128406], [128420, 128420], [128507, 128591], [128640, 128709], [128716, 128716], [128720, 128722], [128725, 128728], [128732, 128735], [128747, 128748], [128756, 128764], [128992, 129003], [129008, 129008], [129292, 129338], [129340, 129349], [129351, 129535], [129648, 129660], [129664, 129674], [129678, 129734], [129736, 129736], [129741, 129756], [129759, 129770], [129775, 129784]].freeze
    # Generated from MRI's Onigmo \p{Emoji_Modifier} ctype table.
    UNICODE_EMOJI_MODIFIER_RANGES = [[127995, 127999]].freeze

    UNICODE_BLOCK_RANGES = {
      "Basic_Latin" => [[0x0000, 0x007F]], "Latin_1_Supplement" => [[0x0080, 0x00FF]],
      "Latin_Extended_A" => [[0x0100, 0x017F]], "Latin_Extended_B" => [[0x0180, 0x024F]],
      "IPA_Extensions" => [[0x0250, 0x02AF]], "Spacing_Modifier_Letters" => [[0x02B0, 0x02FF]],
      "Combining_Diacritical_Marks" => [[0x0300, 0x036F]], "Greek_and_Coptic" => [[0x0370, 0x03FF]],
      "Cyrillic" => [[0x0400, 0x04FF]], "Armenian" => [[0x0530, 0x058F]],
      "Hebrew" => [[0x0590, 0x05FF]], "Arabic" => [[0x0600, 0x06FF]],
      "Syriac" => [[0x0700, 0x074F]], "Arabic_Supplement" => [[0x0750, 0x077F]],
      "Devanagari" => [[0x0900, 0x097F]], "Bengali" => [[0x0980, 0x09FF]],
      "Gurmukhi" => [[0x0A00, 0x0A7F]], "Gujarati" => [[0x0A80, 0x0AFF]],
      "Oriya" => [[0x0B00, 0x0B7F]], "Tamil" => [[0x0B80, 0x0BFF]],
      "Telugu" => [[0x0C00, 0x0C7F]], "Kannada" => [[0x0C80, 0x0CFF]],
      "Malayalam" => [[0x0D00, 0x0D7F]], "Thai" => [[0x0E00, 0x0E7F]],
      "Lao" => [[0x0E80, 0x0EFF]], "Tibetan" => [[0x0F00, 0x0FFF]],
      "Myanmar" => [[0x1000, 0x109F]], "Georgian" => [[0x10A0, 0x10FF]],
      "Hangul_Jamo" => [[0x1100, 0x11FF]], "Ethiopic" => [[0x1200, 0x137F]],
      "Cherokee" => [[0x13A0, 0x13FF]], "Canadian_Aboriginal" => [[0x1400, 0x167F]],
      "Ogham" => [[0x1680, 0x169F]], "Runic" => [[0x16A0, 0x16FF]],
      "Khmer" => [[0x1780, 0x17FF]], "Mongolian" => [[0x1800, 0x18AF]],
      "Hiragana" => [[0x3040, 0x309F]], "Katakana" => [[0x30A0, 0x30FF]],
      "Bopomofo" => [[0x3100, 0x312F]], "CJK_Unified_Ideographs" => [[0x4E00, 0x9FFF]],
      "Yi" => [[0xA000, 0xA4CF]], "Hangul_Syllables" => [[0xAC00, 0xD7AF]],
      "CJK_Compatibility" => [[0x3300, 0x33FF]], "CJK_Compatibility_Forms" => [[0xFE30, 0xFE4F]],
      "Halfwidth_and_Fullwidth_Forms" => [[0xFF00, 0xFFEF]], "Emoticons" => [[0x1F600, 0x1F64F]],
      "Miscellaneous_Symbols" => [[0x2600, 0x26FF]], "Dingbats" => [[0x2700, 0x27BF]],
      "Mathematical_Operators" => [[0x2200, 0x22FF]], "Geometric_Shapes" => [[0x25A0, 0x25FF]],
      "Letterlike_Symbols" => [[0x2100, 0x214F]], "Currency_Symbols" => [[0x20A0, 0x20CF]],
      "General_Punctuation" => [[0x2000, 0x206F]],
      "CJK_Symbols_and_Punctuation" => [[0x3000, 0x303F]],
      "Greek_Extended" => [[0x1F00, 0x1FFF]],
      "Latin_Extended_Additional" => [[0x1E00, 0x1EFF]],
      "Latin_Extended_C" => [[0x2C60, 0x2C7F]],
      "Latin_Extended_D" => [[0xA720, 0xA7FF]],
      "Latin_Extended_E" => [[0xAB30, 0xAB6F]],
      "Latin_Extended_F" => [[0x10780, 0x107BF]],
      "Latin_Extended_G" => [[0x1DF00, 0x1DFFF]],
      "Supplemental_Arrows_A" => [[0x27F0, 0x27FF]],
      "Supplemental_Mathematical_Operators" => [[0x2A00, 0x2AFF]],
      "Transport_and_Map_Symbols" => [[0x1F680, 0x1F6FF]],
      "Enclosed_Alphanumerics" => [[0x2460, 0x24FF]],
      "Enclosed_Alphanumeric_Supplement" => [[0x1F100, 0x1F1FF]],
      "Mathematical_Alphanumeric_Symbols" => [[0x1D400, 0x1D7FF]],
      "CJK_Compatibility_Ideographs" => [[0xF900, 0xFAFF]],
      "CJK_Compatibility_Ideographs_Supplement" => [[0x2F800, 0x2FA1F]],
      "CJK_Strokes" => [[0x31C0, 0x31EF]],
      "Ideographic_Description_Characters" => [[0x2FF0, 0x2FFF]],
      "CJK_Radicals_Supplement" => [[0x2E80, 0x2EFF]],
      "Katakana_Phonetic_Extensions" => [[0x31F0, 0x31FF]],
      "Kana_Supplement" => [[0x1B000, 0x1B0FF]],
      "CJK_Unified_Ideographs_Extension_A" => [[0x3400, 0x4DBF]],
      "CJK_Unified_Ideographs_Extension_B" => [[0x20000, 0x2A6DF]],
      "CJK_Unified_Ideographs_Extension_C" => [[0x2A700, 0x2B73F]],
      "CJK_Unified_Ideographs_Extension_D" => [[0x2B740, 0x2B81F]],
      "CJK_Unified_Ideographs_Extension_E" => [[0x2B820, 0x2CEAF]],
      "CJK_Unified_Ideographs_Extension_F" => [[0x2CEB0, 0x2EBEF]],
      "CJK_Unified_Ideographs_Extension_G" => [[0x30000, 0x3134F]],
      "CJK_Unified_Ideographs_Extension_H" => [[0x31350, 0x323AF]],
      "CJK_Unified_Ideographs_Extension_I" => [[0x2EBF0, 0x2EE5F]],
      "CJK_Unified_Ideographs_Extension_J" => [[0x323B0, 0x3347F]],
      "Vertical_Forms" => [[0xFE10, 0xFE1F]],
      "Kawi" => [[0x11F00, 0x11F5F]],
      "Tangsa" => [[0x16A70, 0x16ACF]],
      "Toto" => [[0x1E290, 0x1E2BF]],
      "Wancho" => [[0x1E2C0, 0x1E2FF]],
      "Medefaidrin" => [[0x16E40, 0x16E9F]],
      "Miao" => [[0x16F00, 0x16F9F]],
      "Bamum_Supplement" => [[0x16800, 0x16A3F]],
      "Pahawh_Hmong" => [[0x16B00, 0x16B8F]],
      "Makasar" => [[0x11EE0, 0x11EFF]],
      "Bamum" => [[0xA6A0, 0xA6FF]],
      "Sundanese_Supplement" => [[0x1CC0, 0x1CCF]],
      "Batak" => [[0x1BC0, 0x1BFF]],
      "Lisu" => [[0xA4D0, 0xA4FF]],
      "Ol_Chiki" => [[0x1C50, 0x1C7F]],
      "Bassa_Vah" => [[0x16AD0, 0x16AFF]],
      "Nag_Mundari" => [[0x1E4D0, 0x1E4FF]],
      "Ol_Onal" => [[0x1E5D0, 0x1E5FF]],
      "Mende_Kikakui" => [[0x1E800, 0x1E8DF]],
      "Nyiakeng_Puachue_Hmong" => [[0x1E100, 0x1E14F]],
      "NKo" => [[0x07C0, 0x07FF]],
      "Coptic" => [[0x2C80, 0x2CFF]],
      "Cyrillic_Extended_C" => [[0x1C80, 0x1C8F]],
      "Cyrillic_Extended_A" => [[0x2DE0, 0x2DFF]],
      "Cyrillic_Extended_B" => [[0xA640, 0xA69F]],
      "Cyrillic_Extended_D" => [[0x1E030, 0x1E08F]],
      "Georgian_Extended" => [[0x1C90, 0x1CBF]],
      "Arabic_Presentation_Forms_A" => [[0xFB50, 0xFDFF]],
      "Arabic_Extended_A" => [[0x08A0, 0x08FF]],
      "Arabic_Extended_B" => [[0x0870, 0x089F]],
      "Arabic_Extended_C" => [[0x10EC0, 0x10EFF]],
      "Arabic_Mathematical_Alphabetic_Symbols" => [[0x1EE00, 0x1EEFF]],
      "Devanagari_Extended" => [[0xA8E0, 0xA8FF]],
      "Devanagari_Extended_A" => [[0x11B00, 0x11B5F]],
      "Kana_Extended_A" => [[0x1B100, 0x1B12F]],
      "Kana_Extended_B" => [[0x1AFF0, 0x1AFFF]],
      "Arabic_Presentation_Forms_B" => [[0xFE70, 0xFEFF]],
      "Adlam" => [[0x1E900, 0x1E95F]]
    }.freeze

    def script_match?(character, ranges)
      codepoint = character.codepoints.first
      # MRI/Onigmo stores each Unicode property as sorted code-point ranges
      # and checks membership with a binary search. Keep the same O(log n)
      # lookup for the bytecode class predicate instead of scanning every range.
      lower = 0
      upper = ranges.length - 1
      while lower <= upper
        middle = (lower + upper) / 2
        range = ranges[middle]
        if codepoint < range[0]
          upper = middle - 1
        elsif codepoint <= range[1]
          return true
        else
          lower = middle + 1
        end
      end
      false
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

    def emoji?(character)
      script_match?(character, UNICODE_EMOJI_RANGES)
    end

    def emoji_presentation?(character)
      script_match?(character, UNICODE_EMOJI_PRESENTATION_RANGES)
    end

    def emoji_modifier?(character)
      script_match?(character, UNICODE_EMOJI_MODIFIER_RANGES)
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

    def block?(name, character)
      script_match?(character, UNICODE_BLOCK_RANGES.fetch(name))
    end
  end
end

# rubocop:enable Layout/LineLength, Layout/IndentationWidth, Layout/EmptyLineBetweenDefs, Layout/IndentationConsistency, Style/NumericLiterals
