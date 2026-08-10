# Ruby 4.0.6 Regexp 機能カバレッジと Onibi の今後のタスク

この文書は、MRI Ruby 4.0.6 の公式 Regexp / MatchData 仕様と、現在の Onibi 実装を突き合わせたスナップショットである。Onibi の判定は、実装・既存テスト・Core MVP の設計文書を基準にしている。Ruby のベースラインを更新する際にはこの表も再検証する。

## Onibi のカバレッジ判定

## 判定記号

| 記号 | 意味 |
| --- | --- |
| ✅ | Onibi の公開 API で、Core MVP の対象範囲において実装済み。 |
| ◐ | 一部だけ実装済み、または Ruby 4.0.6 と意味・戻り値・エラーが一致しない。 |
| ❌ | 未実装。 |
| 対象外 | 現在の Onibi の設計スコープ外。将来再検討する。 |

## Ruby 4.0.6 の機能一覧

### パターン構文

| 分類 | Ruby 4.0.6 の機能 | 代表例 | Onibi | 判定理由 |
| --- | --- | --- | --- | --- |
| リテラル | 文字・Unicode 文字 | abc、こんにちは | ✅ | UTF-8 と ASCII-8BIT の範囲で実装・テスト済み。 |
| メタ文字 | . ? - + * ^ バックスラッシュ 縦棒 $ ( ) [ ] { } | a\+、バックスラッシュ | ◐ | エスケープ対象の一部を実装。Ruby の escape sequence 全体は未実装。 |
| 任意文字 | 改行以外の任意の 1 文字 | . | ◐ | Onibi は現在 . が改行にも一致する。Ruby の /m に相当する挙動が常時有効。 |
| 文字クラス | 列挙 | [abc] | ✅ | 実装済み。 |
| 文字クラス | 否定 | [^a] | ✅ | 実装済み。 |
| 文字クラス | 範囲 | [a-z]、[a-cd-f] | ✅ | 基本範囲を実装済み。 |
| 文字クラス | クラス内のエスケープ | [\]]、[\-] | ◐ | クラス全体を単純な文字列として処理するため、Ruby と同じ意味にならない場合がある。 |
| 文字クラス | ネスト | [a-z[0-9]] | ✅ | 実装済み。 |
| 文字クラス | 交差 | [a-w&&[^c-g]z] | ✅ | && による集合演算を実装済み。 |
| 省略クラス | 単語文字 | \w | ◐ | ASCII の [A-Za-z0-9_] 相当のみ。Ruby の Unicode 拡張ではない。 |
| 省略クラス | 非単語文字 | \W | ✅ | 実装済み。 |
| 省略クラス | ASCII 数字 | \d | ✅ | [0-9] 相当を実装済み。 |
| 省略クラス | 非数字 | \D | ✅ | 実装済み。 |
| 省略クラス | 16 進数字・非 16 進数字 | \h、\H | ✅ | 実装済み。 |
| 省略クラス | 空白・非空白 | \s、\S | ✅ | 実装済み。 |
| 省略クラス | 改行シーケンス | \R | ✅ | CR、LF、CRLF、NEL、LSEP、PSEP 等を実装済み。 |
| アンカー | 行頭・行末 | ^、$ | ◐ | 基本的な行頭・行末を実装。ただし Ruby では ^/$ は常に行境界であり、Onibi の multiline オプションと意味が一致しない。 |
| アンカー | 文字列先頭・末尾 | \A、\Z、\z | ✅ | 実装済み。 |
| アンカー | 単語境界 | \b、\B | ✅ | 実装済み。 |
| アンカー | 現在のマッチ位置 | \G | ✅ | 実装済み。 |
| アンカー | マッチリセット | \K | ✅ | match span reset として実装済み。 |
| alternation | 左から右の選択 | a|b、(a|b) | ✅ | 実装済み。左端優先・捕捉優先順位は要追加検証。 |
| 量指定子 | 0 回以上、1 回以上、0/1 回 | *、+、? | ✅ | Greedy の基本形を実装済み。 |
| 量指定子 | 回数固定・最小以上・範囲 | {n}、{min,}、{min,max} | ✅ | Greedy の基本形を実装済み。 |
| 量指定子 | 最大回数以下 | {,max} | ❌ | 現在の parser は空の最小値を受理しない。 |
| 量指定子 | Lazy | *?、+?、??、{1,3}? | ✅ | 実装済み。 |
| 量指定子 | Possessive | *+、++、?+ | ✅ | 実装済み。counting range の possessive は Ruby 仕様に合わせて拒否。 |
| グループ | 番号付き捕捉 | (abc) | ✅ | MatchData の番号付き capture を実装済み。 |
| グループ | 非捕捉グループ | (?:abc) | ✅ | 実装済み。 |
| グループ | 名前付き捕捉 | (?<name>abc)、(?'name'abc) | ✅ | named capture を実装済み。 |
| グループ | atomic group | (?>abc) | ✅ | 専用 AST と非バックトラッキング matcher を実装済み。 |
| backreference | 番号参照・名前参照 | \1、\k<name> | ✅ | 実装済み。 |
| subexpression call | 番号・名前による再帰呼出し | \g<name>、\g1 | ✅ | 実装済み。 |
| 条件式 | capture の有無による分岐 | (?(1)yes|no) | ✅ | 番号・名前条件を実装済み。 |
| absence operator | 含まれない部分のマッチ | (?~pat) | ✅ | Ruby 4.0 の代表例を実装・テスト済み。 |
| lookaround | lookahead | (?=pat)、(?!pat) | ✅ | 実装済み。 |
| lookaround | lookbehind | (?<=pat)、(?<!pat) | ✅ | 固定幅 AST 検証付きで実装済み。 |
| コメント | パターン内コメント | (?#comment) | ✅ | lexer で無視し、capture を生成しない。unterminated comment は RegexpError。 |

### Unicode、POSIX、エンコーディング

| 分類 | Ruby 4.0.6 の機能 | 代表例 | Onibi | 判定理由 |
| --- | --- | --- | --- | --- |
| Unicode property | 正・負の property | \p{Alpha}、\P{Alpha}、\p{^Alpha} | ✅ | 実装済み。 |
| Unicode category | Letter、Mark、Number、Punctuation 等 | \p{Lu}、\p{Nd} | ✅ | 実装済み。 |
| Unicode script/block | Script / Block | \p{Hiragana}、\p{InBasic_Latin} | ✅ | 実装済み。 |
| POSIX class | digit、xdigit、upper、lower、alpha、alnum | [[:digit:]] | ✅ | 実装済み。 |
| POSIX class | space、blank、cntrl、graph、print、punct | [[:space:]] | ✅ | 実装済み。 |
| Ruby 拡張 POSIX | ascii、word | [[:ascii:]]、[[:word:]] | ✅ | 実装済み。 |
| encoding | UTF-8 | é と UTF-8 入力 | ◐ | UTF-8 の基本一致、不正 pattern/input の例外、literal/class の Unicode case folding を実装済み。全 Unicode fold と encoding mode は未対応。 |
| encoding | ASCII-8BIT | abc のバイト列 | ◐ | ASCII-8BIT の基本一致、NOENCODING の binary byte pattern、invalid byte と互換性エラーを実装。Unicode property は constructor で拒否する。全組合せは未検証。 |
| encoding | US-ASCII | ASCII の pattern/input | ◐ | ASCII-only の互換性は扱うが、Regexp の source encoding/fixed encoding と同一ではない。 |
| encoding | EUC-JP、Windows-31J 等 | /pat/e、/pat/s | ◐ | 同一 encoding の literal/class/property、`match`/`match?`、ASCII pattern の cross-encoding、互換性エラーを基本対応。constructor encoding mode は未実装。 |
| encoding mode | encoding 指定 | /pat/u、/pat/n、/pat/e、/pat/s | ❌ | Ruby の regexp option として未実装。 |
| encoding mode | fixed/no encoding | Regexp::FIXEDENCODING、Regexp::NOENCODING | ◐ | integer option、encoding/fixed_encoding? introspection、ASCII-8BIT pattern、Unicode property validation、binary input の byte match を実装。完全な互換性は未対応。 |

### モード・Regexp API

| 分類 | Ruby 4.0.6 の機能 | Onibi | 判定理由 |
| --- | --- | --- | --- |
| constructor | Regexp.new(string, options = 0, timeout: nil) | ◐ | Onibi は pattern と Array[String] の独自形式。整数/文字列 flag、Regexp 引数、timeout は未対応。 |
| constructor | Regexp.compile | ◐ | メソッドはあるが Ruby の .new と同じ引数互換性はない。 |
| mode | i / IGNORECASE | ◐ | ignorecase 配列 option で literal/class の Unicode case folding を実装。inline modifier と全構文への fold 伝播は未対応。 |
| mode | m / MULTILINE | ◐ | Onibi の multiline は ^/$ の判定にも影響する。Ruby の m は dot-all で ^/$ を変更しない。 |
| mode | x / EXTENDED | ◐ | `extended` option で pattern の whitespace と top-level `#` comment を無視する。escaped whitespace と inline modifier は未対応。 |
| mode | o / interpolation | 対象外 | Onibi は /.../ literal を parse せず、文字列 pattern を受け取る設計。 |
| mode | inline modifier | (?i)、(?-i)、(?i:pat) | ❌ | 未実装。 |
| matching | Regexp#match | ◐ | Onibi::MatchData または nil を返すが、capture、offset、regexp、pre/post match 等が不完全。 |
| matching | Regexp#match? | ✅ | boolean を返す基本 API は実装済み。 |
| matching | Regexp#=~、Regexp#===、unary ~ | ❌ | 未実装。 |
| matching state | $~、$&、$1 等 | 対象外 | global match variables を変更しない opt-in API という設計。 |
| introspection | source | ❌ | 未実装。 |
| introspection | options | ◐ | Onibi は option 名の配列を返す。Ruby の整数 bit mask とは異なる。 |
| introspection | encoding、fixed_encoding?、casefold? | ❌ | 未実装。 |
| introspection | timeout、timeout= | ❌ | 未実装。 |
| object semantics | ==、eql?、hash、inspect、to_s | ❌ | Ruby 互換の regexp object semantics は未実装。 |
| class utility | Regexp.escape、Regexp.union | ❌ | 未実装。 |
| class utility | Regexp.last_match | 対象外 | global match state を持たない設計。 |
| class utility | Regexp.linear_time? | ❌ | Onibi の NFA/DFA 実行器に対応する公開判定 API は未実装。 |
| class utility | Regexp.timeout、Regexp.timeout= | ❌ | 未実装。 |
| serialization | as_json、json_create、to_json | ❌ | JSON 拡張との連携は未実装。 |
| integration | String#match、scan、gsub、sub | 対象外 | Core MVP/v1 の non-goal。Onibi を明示的に呼び出す API を優先する。 |

### MatchData API

Ruby 4.0.6 の MatchData は、番号・名前による値取得だけでなく、文字単位/byte 単位の位置、前後の文字列、元の regexp と入力文字列、名前一覧、構造化分解などを提供する。

| Ruby 4.0.6 の機能 | 代表的なメソッド | Onibi | 判定理由 |
| --- | --- | --- | --- |
| full match / numbered capture | []、captures、to_a | ◐ | メソッドはあるが、Regexp#match が capture を正しく構築していない。負数・範囲・名前 index も未対応。 |
| capture count | length、size | ◐ | length はある。size は未実装。 |
| character offsets | begin、end、offset | ◐ | begin/end は初期実装のみ。offset、全 capture offsets、Unicode の byte/character 差は未完成。 |
| byte offsets | bytebegin、byteend、byteoffset | ❌ | 未実装。 |
| matched length | match_length | ❌ | 未実装。 |
| source string | string | ❌ | 未実装。 |
| original regexp | regexp | ❌ | 未実装。 |
| surrounding text | pre_match、post_match | ❌ | 未実装。 |
| named captures | names、named_captures | ❌ | named capture 自体が未実装。 |
| indexed extraction | values_at | ❌ | 未実装。 |
| formatting / identity | inspect、to_s、==、eql?、hash | ❌ | 未実装。 |
| modern destructuring | deconstruct、deconstruct_keys | ❌ | 未実装。 |

## 現時点の結論

Onibi は Core MVP の「文字列 pattern を明示的にコンパイルし、match? で検索する」範囲は実装済みである。一方、Ruby 4.0.6 全体との互換性では、次の差が大きい。

1. Regexp#match の tagged capture と MatchData が未完成。
2. .、^、$、m の意味が Ruby 4.0.6 と一致しない。
3. Unicode property、POSIX class、\D/\W/\H/\S/\R、境界アンカーがない。
4. Ruby 互換の encoding matrix、constructor flags、inline modes、introspection、timeout、Regexp/MatchData utility API がない。
5. コメント構文と一部の高度な public API は未実装である。

## 今後の実行タスク

依存関係を考慮し、上から順に着手する。各タスクは既存の開発ルールに従い、専用 worktree、先行する acceptance test、差分テスト、RuboCop、Ruby 4.0.6 CI、squash merge を必須とする。

### REGEXP-001 [Complete] — MatchData と tagged capture を完成させる

- Priority: P0
- Dependencies: CORE-013, CORE-015
- Regexp#match が番号付き/unmatched/nested/repeated capture を返すようにする。
- MatchData の []、captures、to_a、length、size、begin、end、offset を Ruby の観測値に合わせる。
- Unicode の character offset と byte offset を分離する。
- acceptance: match? と match の両方で MRI 4.0.6 と full/capture/offset を比較する。

### REGEXP-002 [Complete] — 基本構文の Ruby 意味を修正する

- Priority: P0
- Dependencies: REGEXP-001
- . を通常時は改行に一致させず、m で改行に一致させる。
- ^/$ は常に Ruby の行境界として扱い、multiline option で意味を変えない。
- \A、\Z、\z を追加する。
- {,max} を追加し、量指定子の構文エラーと greedy 境界を MRI と揃える。
- acceptance: 改行、末尾改行、空文字列、bounded quantifier の differential corpus を追加する。

### REGEXP-003 [Complete] — 省略クラスと境界アンカーを拡張する

- Priority: P0
- Dependencies: REGEXP-002
- \D、\W、\H、\S、\h、\R を lexer/AST/VM/fallback に追加する。
- \b、\B、\G を zero-width assertion として追加する。
- \s と \R の ASCII/Unicode/CRLF の差を定義する。
- acceptance: ASCII-8BIT、UTF-8、CRLF、NEL/LSEP/PSEP の differential cases を追加する。

### REGEXP-004 [Complete] — character class の完全な構文を実装する

- Priority: P1
- Dependencies: REGEXP-003
- クラス内 escape、literal hyphen/bracket、nested class、&& intersection を実装する。
- parser と matcher で class AST を構造化し、文字列の再解釈をやめる。
- acceptance: [a-z[0-9]]、[a-w&&[^c-g]z]、[\-\]] 等を MRI と比較する。

### REGEXP-005 [Complete] — Unicode property と POSIX class を実装する

- Priority: P1
- Dependencies: REGEXP-004, REGEXP-008
- \p{...}、\P{...}、\p{^...} と Unicode category/script/block を追加する。
- POSIX の digit、xdigit、upper、lower、alpha、alnum、space、blank、cntrl、graph、print、punct を追加する。
- Ruby 拡張の ascii、word も追加する。
- Ruby 4.0.6 が参照する Unicode データと更新手順を固定する。
- acceptance: Unicode property の代表値と invalid property error を differential test する。

### REGEXP-006 [Complete] — quantifier の lazy / possessive semantics を実装する

- Priority: P1
- Dependencies: REGEXP-001, REGEXP-002
- *?、+?、??、{min,max}? の lazy capture を実装する。
- *+、++、?+ の no-backtracking semantics を実装する。
- counting range の possessive 非対応という Ruby 仕様も error corpus に固定する。
- acceptance: match span と capture boundary を MRI と比較する。

### REGEXP-007 [Complete] — groups、backreference、assertion を段階的に実装する

- Priority: P1
- Dependencies: REGEXP-001, REGEXP-003
- [x] 非捕捉 group、named capture、named/numbered backreference を追加する。
- [x] positive/negative lookahead/lookbehind と fixed-width lookbehind 検証を追加する。
- [x] atomic group を個別の AST/VM 機能として追加する。
- [x] conditional group を個別の AST/VM 機能として追加する。
- [x] subexpression call を個別の AST/VM 機能として追加する。
- [x] absence operator を個別の AST/VM 機能として追加する。
- [x] \K match reset を capture/span 設計と合わせて追加する。
- acceptance: 各構文を独立 fixture とし、parse error、capture、zero-width span を比較する。

### REGEXP-008 — encoding と case folding を Ruby 互換にする

- Priority: P1
- Dependencies: REGEXP-001, REGEXP-005
- US-ASCII、UTF-8、ASCII-8BIT、EUC-JP、Windows-31J の pattern/input matrix を実装する。
- [x] invalid encoded pattern/input、compatible ASCII、Encoding::CompatibilityError の基本条件を揃える。
- [x] literal と character class の Unicode case folding と ignorecase を実装する。
- [x] `Regexp::NOENCODING` と binary input の byte 単位 match を追加する。
- [x] EUC-JP / Windows-31J の property、`match`、ASCII-8BIT property validation を追加する。
- /u、/e、/s 相当と `FIXEDENCODING` の完全な互換性を追加する。
- 全 encoding matrix と encoding mode の発生条件を揃える。
- acceptance: Ruby 4.0.6 の encoding matrix を fixture 化する。

### REGEXP-009 — mode と source preprocessing を実装する

- Priority: P1
- Dependencies: REGEXP-002, REGEXP-007
- [x] extended mode x の whitespace/comment 処理を lexer 前処理として追加する。
- [x] (?#comment) を追加する。
- inline modifier (?i)、(?-i)、(?i:...) 等を scope 付き option AST にする。
- Ruby literal interpolation 自体は文字列 API の範囲外として維持するか、別 API の要否を決める。
- acceptance: mode の on/off scope と comment/whitespace の parse/match を比較する。

### REGEXP-010 — Regexp public API を拡張する

- Priority: P1
- Dependencies: REGEXP-001, REGEXP-008, REGEXP-009
- constructor の Ruby 互換 flags、Regexp 引数、keyword timeout を追加する。
- source、encoding、fixed_encoding?、casefold?、==、eql?、hash、inspect、to_s を追加する。
- Regexp#=~、===、unary ~ と offset 引数を追加する。
- Regexp.escape、Regexp.union、Regexp.last_match を追加する。
- global match variables を opt-in replacement で扱うか、Onibi 独自 API として明確に分離する。
- acceptance: public API inventory の全メソッドを MRI と比較する。

### REGEXP-011 — timeout、linear-time 判定、ReDoS 制御を追加する

- Priority: P2
- Dependencies: REGEXP-007, REGEXP-010
- class/instance timeout と timeout error を追加する。
- Regexp.linear_time? 相当の安全性判定を追加する。
- NFA/DFA のメモリ上限、実行ステップ上限、割り込み・キャンセル方針を整理する。
- backreference/lookaround/atomic group を含む危険パターンの安全性を differential/property test する。

### REGEXP-012 — MatchData の完全な Ruby API と統合を追加する

- Priority: P2
- Dependencies: REGEXP-001, REGEXP-010
- bytebegin、byteend、byteoffset、match_length、pre_match、post_match、string、regexp、names、named_captures、values_at を追加する。
- inspect、to_s、==、eql?、hash、deconstruct、deconstruct_keys を追加する。
- String/Symbol の match、match?、scan、gsub、sub 統合を、v1 non-goal の解除判断とともに設計する。
- acceptance: Ruby 4.0.6 MatchData メソッド一覧を網羅する。

## 参照資料

- [Ruby 4.0.6 Regexp class documentation](https://docs.ruby-lang.org/en/4.0/Regexp.html)
- [Ruby 4.0.6 MatchData class documentation](https://docs.ruby-lang.org/en/4.0/MatchData.html)
- [Onibi design](onibi-design.md)
- [Core MVP task list](core-mvp-task-list.md)

Ruby 4.0.6 の公式資料では、Regexp の構文として special characters、source literals、character classes、shorthand classes、anchors、alternation、quantifiers、groups/captures、Unicode、POSIX bracket expressions、comments を扱い、さらに modes、encodings、timeouts、linear-time optimization、公開 API を定義している。本表はそれらを Onibi の実装単位に分解したものである。
