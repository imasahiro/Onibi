# Unicode execution notes

MRI uses Onigmo for regular expression execution. Onigmo keeps the encoding
operation separate from the VM operation. The encoding layer decodes one
character at the current byte position and returns its case-fold sequence.
The VM then compares that sequence with the compiled operand and advances the
input by the number of source bytes that it consumed.

The important properties are:

* Unicode case-fold data is generated once and stored in tables.
* A fold can produce more than one code point. The matcher keeps that length
  in the current candidate; it does not change the source AST.
* Character classes use compiled predicates. They do not parse a class for
  every input character.
* Search and backtracking operate on VM candidates. Each candidate contains
  the input position and the local capture state.

Onibi follows the same split:

* `IRGen` stores the fold sequence and its source segments in each literal
  bytecode operand.
* `Interpreter` decodes the Ruby string with `each_char` and returns a list of
  consumed code-point lengths for one operand.
* `CompiledClassPredicate` and `ClassPredicates` cache the parsed class and
  use Unicode property tables for class tests.
* Sequence and quantifier instructions carry the candidate length in the
  operand stack state. They never read the compiler AST at run time.

Do not normalize the complete input string before execution. Full-string
normalization loses source boundaries and breaks captures. Do not infer fold
boundaries from a fixed pattern. The compiler must emit the fold segments, and
the interpreter must use those segments for every literal and class operand.

The reference behavior is the MRI/Onigmo behavior for the active Ruby
encoding. Differential tests must compare the complete match and capture
boundaries, not only the boolean result.
