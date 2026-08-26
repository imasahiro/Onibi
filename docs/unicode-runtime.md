# Unicode runtime design

## MRI and Onigmo

MRI uses Onigmo as its regular expression engine. The compiler keeps the
encoding with the compiled pattern. The executor reads one encoded character
from the input pointer with the encoding decoder. It does not convert the
whole input to Ruby strings.

Character classes use different bytecode forms for different data:

- ASCII-only classes use a fixed bitmap.
- Multibyte classes use a table of encoded ranges.
- Mixed classes use both the bitmap and the multibyte table.
- Unicode properties use generated Unicode ctype tables.

The generated tables are sorted code-point ranges. A class test performs a
binary search. Property names become ctype identifiers during compilation.
The executor therefore does not parse a property name or build a property
regular expression for each character.

Ignore-case matching also starts during compilation. Onigmo stores simple
case-fold alternatives in the compiled class. Multi-character folds use a
separate compiled path. This keeps the normal one-character path short.

Onigmo also has a match cache for selected backtracking points. The cache key
contains the input position and the compiled instruction point. It prevents
repeating failed backtracking work.

Sources: `regexec.c` in the MRI repository and the Onigmo `doc/RE` reference.

## Onibi mapping

Onibi follows the same data split:

- `CompiledClassPredicate` builds a 256-entry ASCII table for byte classes.
- `UnicodePropertyScripts` and `UnicodePropertyCategories` contain generated,
  sorted code-point ranges.
- `script_match?` and `range_member?` use binary search over those ranges.
- The compiler validates and normalizes property names. Bytecode operands use
  the normalized name, so the interpreter does not parse property syntax.
- Case-fold alternatives are prepared before execution. Full folds are kept
  separate from simple one-character folds.

The current interpreter still creates a Ruby character array for each input.
This is correct, but it differs from MRI's pointer cursor and allocates for
the complete input before the first instruction runs. A future optimization
can replace that array with an encoding-aware cursor and a memoized boundary
table. The bytecode contract must stay unchanged: positions remain character
positions, while match offsets remain byte offsets.

The generated tables must be refreshed with the MRI version used by the
project. Unicode data changes can alter property results. Tests must compare
both positive and negative property matches at ASCII, BMP, supplementary, and
unassigned code points.
