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
| メタ文字 | . ? - + * ^ バックスラッシュ 縦棒 $ ( ) [ ] { } | a\+、バックスラッシュ | ◐ | common control-character escapes、caret control escapes（`\\cX`、`\\C-X`）、hex and Unicode escapes、メタ文字 escape（`\\M-X`、`\\M-\\C-X`、`\\M-\\xNN`）を実装。その他の meta escape 組み合わせは未実装。 |
| 任意文字 | 改行以外の任意の 1 文字 | . | ✅ | 通常は改行を除外し、`multiline` option で Ruby の dot-all 相当になる。 |
| 文字クラス | 列挙 | [abc] | ✅ | 実装済み。 |
| 文字クラス | 否定 | [^a] | ✅ | 実装済み。 |
| 文字クラス | 範囲 | [a-z]、[a-cd-f] | ✅ | 基本範囲を実装済み。 |
| 文字クラス | クラス内のエスケープ | [\]]、[\-]、[\x41]、[\u{1F600}] | ◐ | character class escape decoder で control（`\\cX` / `\\C-X`）/meta（`\\M-X`）/hex/Unicode escape、Unicode property escape（`[\\p{...}]` / `[\\P{...}]`）と literal escape を処理する。POSIX/全 Unicode class escape の互換性は未完了。 |
| 文字クラス | ネスト | [a-z[0-9]] | ✅ | 実装済み。 |
| 文字クラス | 交差 | [a-w&&[^c-g]z] | ✅ | && による集合演算を実装済み。 |
| 省略クラス | 単語文字 | \w | ✅ | ASCII の [A-Za-z0-9_] 相当。Ruby 4.0.6 の `\\w` も Unicode word ではないため、ASCII-only semantics が一致する。 |
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
| 量指定子 | 最大回数以下 | {,max} | ✅ | 空の最小値を 0 として parser と matcher が処理する。`{,max}` の空・上限・超過ケースを acceptance test 済み。 |
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
| Unicode property | 正・負の property | \p{Alpha}、\P{Alpha}、\p{^Alpha} | ✅ | 実装済み。Unicode property pattern は source encoding を fixed encoding として introspection する。 |
| Unicode category | Letter、Mark、Number、Punctuation 等 | \p{Lu}、\p{Nd} | ✅ | 実装済み。 |
| Unicode script/block | Script / Block | \p{Hiragana}、\p{InBasic_Latin} | ✅ | 実装済み。 |
| POSIX class | digit、xdigit、upper、lower、alpha、alnum | [[:digit:]] | ✅ | 実装済み。 |
| POSIX class | space、blank、cntrl、graph、print、punct | [[:space:]] | ✅ | 実装済み。 |
| Ruby 拡張 POSIX | ascii、word | [[:ascii:]]、[[:word:]] | ✅ | 実装済み。 |
| encoding | UTF-8 | é と UTF-8 入力 | ◐ | UTF-8 の基本一致、不正 pattern/input の例外、literal/class の Unicode case folding、non-ASCII pattern の implicit FIXEDENCODING を実装済み。全 Unicode fold と encoding mode は未対応。 |
| encoding | ASCII-8BIT | abc のバイト列 | ◐ | ASCII-8BIT の基本一致、NOENCODING の binary byte pattern、invalid byte と互換性エラーを実装。Unicode property は constructor で拒否する。全組合せは未検証。 |
| encoding | US-ASCII | ASCII の pattern/input | ◐ | ASCII-only の互換性は扱うが、Regexp の source encoding/fixed encoding と同一ではない。 |
| encoding | EUC-JP、Windows-31J 等 | /pat/e、/pat/s | ◐ | 同一 encoding の literal/class/property、`match`/`match?`、ASCII pattern の cross-encoding、互換性エラーを基本対応。constructor encoding mode は未実装。 |
| encoding mode | encoding 指定 | /pat/u、/pat/n、/pat/e、/pat/s | 対象外 | これらは `Regexp.new` の options ではなく regex literal の表記。Onibi は文字列 pattern API で literal parser / interpolation を持たない。 |
| encoding mode | fixed/no encoding | Regexp::FIXEDENCODING、Regexp::NOENCODING | ◐ | integer option、non-ASCII pattern の implicit FIXEDENCODING、encoding/fixed_encoding? introspection、ASCII-8BIT pattern、Unicode property validation、binary input の byte match、固定 encoding と非 ASCII input の互換性検証を実装。完全な互換性は未対応。 |

### モード・Regexp API

| 分類 | Ruby 4.0.6 の機能 | Onibi | 判定理由 |
| --- | --- | --- | --- |
| constructor | Regexp.new(string, options = 0, timeout: nil) | ◐ | Onibi は pattern と Array[String] の独自形式だが、既存 Onibi::Regexp と MRI Regexp の source/options によるコピー、timeout keyword、Onibi copy時のtimeout保持/overrideを実装。Ruby 互換 flags の全組合せとMRI Regexpのtimeout copyは未対応。 |
| constructor | Regexp.compile | ◐ | メソッドはあるが Ruby の .new と同じ引数互換性はない。 |
| mode | i / IGNORECASE | ◐ | ignorecase 配列 option で literal/class の Unicode case folding を実装。inline modifier と scoped option AST の fold 伝播を実装。全構文への fold 対応は未完了。 |
| mode | m / MULTILINE | ✅ | `multiline` option は `.` の dot-all 挙動だけを変更し、^/$ は常に行境界として扱う。 |
| mode | x / EXTENDED | ◐ | `extended` option と `Regexp::EXTENDED` integer flag で pattern の whitespace と top-level `#` comment を無視し、escaped whitespace/comment marker を literal として処理する。一部 inline modifier は未対応。 |
| mode | o / interpolation | 対象外 | Onibi は /.../ literal を parse せず、文字列 pattern を受け取る設計。 |
| mode | inline modifier | (?i)、(?-i)、(?m)、(?-m)、(?x)、(?-x)、(?imx)、(?-imx)、(?i:pat) | ◐ | single/combined prefix と、`(?i:pat)` / `(?-i:pat)` / scoped multiline / positive scoped extended mode / negative scoped extended mode / nested mixed extended scopes / scoped combined i/m/x modes の option・lexer処理を実装。任意の混在 scopeは未対応。 |
| matching | Regexp#match | ◐ | Onibi::MatchData または nil を返し、position 引数による検索開始位置、capture、offset、regexp、pre/post match 等を提供する。ただし MatchData の互換性は未完成。 |
| matching | Regexp#match? | ◐ | boolean と position 引数による検索開始位置を実装。Ruby の全エラー・encoding semantics は未完成。 |
| matching | Regexp#=~、Regexp#===、unary ~ | ◐ | `=~` は match begin offset、`===` は boolean、unary `~` は top-level `$_` への match 結果を返す。offset 引数と完全な global match state は未対応。 |
| matching state | $~、$&、$1 等 | 対象外 | global match variables を変更しない opt-in API という設計。 |
| introspection | source | ◐ | 元の pattern を返し、non-fixed ASCII-only pattern は US-ASCII encoding に正規化する。Ruby 互換の frozen/その他 encoding 詳細は未対応。 |
| introspection | options | ◐ | `Regexp#options` はRuby互換の整数bitmaskを返す。array constructor入力を含む全option意味・encoding flagの互換性は未対応。 |
| introspection | encoding、fixed_encoding?、casefold? | ◐ | encoding / fixed_encoding? / casefold? の基本 introspection を実装。Ruby 互換の全 encoding mode は未対応。 |
| introspection | timeout、timeout= | ◐ | class default timeout、instance timeout、timeout keyword、positive timeout validation、match評価、`Regexp::TimeoutError` 相当の専用例外を実装。Rubyの完全な timeout error/copy semantics は未対応。 |
| object semantics | ==、eql?、hash、inspect、to_s | ◐ | `==`、`eql?`、`hash` と基本的な Ruby 形式の `inspect` / `to_s` を実装。`to_s` / `inspect` の Ruby mode flag order（`mix`）と NOENCODING suffix（`n`）も対応。全 encoding/option 表現は未対応。 |
| class utility | Regexp.escape、Regexp.union | ◐ | `Regexp.escape` のSymbol/`to_str`/TypeError coercion、hyphen/control-whitespace escape、ASCII-only result encoding と、文字列 alternatives / 空集合、および compiled pattern の source を扱う `Regexp.union` を実装。compiled pattern の ignorecase、multiline / extended scope、FIXEDENCODING / NOENCODING も保持するが、その他の全オプション互換は未対応。 |
| class utility | Regexp.last_match | 対象外 | global match state を持たない設計。 |
| class utility | Regexp.linear_time? | ◐ | String/MRI Regexp/Onibi Regexpを受け取り、backreference、subexpression call、lookaround、atomic groupを含むpatternを保守的にfalse判定する基本APIを実装。nested quantifierや実行器依存の厳密判定は未対応。 |
| class utility | Regexp.timeout、Regexp.timeout= | ◐ | class-level timeoutのget/setとNumeric validationを実装。Ractor/global state・完全なerror compatibilityは未対応。 |
| serialization | as_json、json_create、to_json | ❌ | JSON 拡張との連携は未実装。 |
| integration | String#match、scan、gsub、sub | 対象外 | Core MVP/v1 の non-goal。Onibi を明示的に呼び出す API を優先する。 |

### MatchData API

Ruby 4.0.6 の MatchData は、番号・名前による値取得だけでなく、文字単位/byte 単位の位置、前後の文字列、元の regexp と入力文字列、名前一覧、構造化分解などを提供する。

| Ruby 4.0.6 の機能 | 代表的なメソッド | Onibi | 判定理由 |
| --- | --- | --- | --- |
| full match / numbered capture | []、captures、to_a | ◐ | full match、numbered capture、Floatのinteger coercion、未知named captureのIndexError、負数・範囲・名前 index の基本取得を実装。全 Ruby extraction/error 互換は未対応。 |
| capture count | length、size | ✅ | length と size を実装済み。 |
| character offsets | begin、end、offset | ◐ | integerの型・範囲検証、named capture index、unmatched capture の `[nil, nil]` offset、全captureのcharacter offsetを実装。全Unicode/encoding差は未検証。 |
| byte offsets | bytebegin、byteend、byteoffset | ◐ | character offsetからbyte offsetを導出し、integer/named indexの型・範囲検証を実装。全encoding matrixは未検証。 |
| matched length | match_length | ◐ | captureのcharacter lengthとinteger/named indexの型・範囲検証を実装。全Ruby error互換は未対応。 |
| source string | string | ◐ | `MatchData#string` を match input として返す。直接構築時の context は未対応。 |
| original regexp | regexp | ◐ | `MatchData#regexp` を元の Onibi::Regexp として返す。直接構築時の context は未対応。 |
| surrounding text | pre_match、post_match | ◐ | match の文字 offset を利用した前後文字列を返す。全 byte offset 互換は未対応。 |
| named captures | names、named_captures | ◐ | named capture、`names`、`named_captures`、string/symbol による `[]` / `values_at` を実装。全 API は未対応。 |
| indexed extraction | values_at | ◐ | integer/Float index、range、負数range normalization、正負の capture index、out-of-range nil、未知named captureのIndexErrorを実装。全 Ruby index 型互換は未対応。 |
| formatting / identity | inspect、to_s、==、eql?、hash | ◐ | Ruby 形式の `MatchData#to_s` / `inspect`、`==` / `eql?` / `hash` の基本値 semantics を実装。全 encoding/context 表現は未対応。 |
| modern destructuring | deconstruct、deconstruct_keys | ◐ | capture-only positional values と Symbol-keyed named capture の分解を実装。Ruby 4.0.6 の全 pattern-matching edge case は未検証。 |

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
- [x] `\h` / `\H` を Ruby の hexadecimal / non-hexadecimal shorthand semantics に揃える。
- \b、\B、\G を zero-width assertion として追加する。
- \s と \R の ASCII/Unicode/CRLF の差を定義する。
- acceptance: ASCII-8BIT、UTF-8、CRLF、NEL/LSEP/PSEP の differential cases を追加する。

### REGEXP-004 [Complete] — character class の完全な構文を実装する

- Priority: P1
- Dependencies: REGEXP-003
- クラス内 escape、literal hyphen/bracket、nested class、&& intersection を実装する。
- parser と matcher で class AST を構造化し、文字列の再解釈をやめる。
- [x] common control-character escapes（`\\n`、`\\r`、`\\t`、`\\f`、`\\v`、`\\a`、`\\e`）を literal AST に接続する。
- [x] hex and Unicode escapes（`\\xNN`、`\\uNNNN`、`\\u{...}`）を literal AST に接続する。
- [x] caret control escapes（`\\cX`、`\\C-X`）を literal AST に接続する。
- [x] meta escapes（`\\M-X`、`\\M-\\C-X`、`\\M-\\xNN`）を ASCII-8BIT の high-bit byte に接続する。
- [x] character class escape decoder を class matcher に接続する。
- [x] character class 内の caret control escapes（`\\cX`、`\\C-X`）を class matcher に接続する。
- [x] ASCII-8BIT character class 内の meta escapes（`\\M-X`、`\\M-\\C-X`、`\\M-\\xNN`）を class matcher に接続する。
- [x] Unicode property escapes（`\\p{...}`、`\\P{...}`、`\\p{^...}`）を class matcher に接続する。
- acceptance: [a-z[0-9]]、[a-w&&[^c-g]z]、[\-\]] 等を MRI と比較する。

### REGEXP-005 [Complete] — Unicode property と POSIX class を実装する

- Priority: P1
- Dependencies: REGEXP-004, REGEXP-008
- \p{...}、\P{...}、\p{^...} と Unicode category/script/block を追加する。
- POSIX の digit、xdigit、upper、lower、alpha、alnum、space、blank、cntrl、graph、print、punct を追加する。
- Ruby 拡張の ascii、word も追加する。
- [x] Hiragana、Katakana、CJK、Hangul など uncased Unicode letter の Alpha/Word 判定を追加する。
- [x] uncased Unicode letter の Upper/Lower 誤判定を修正し、`[[:ascii:]]` を追加する。
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
- [x] `FIXEDENCODING` の ASCII pattern に対する非 ASCII cross-encoding input の拒否を追加する。
- [x] 非 ASCII pattern に対する ASCII-only cross-encoding input を `false` として扱う。
- [x] 非 UTF-8 の ASCII character class と incompatible な非 ASCII input を error ではなく `false` として扱う。
- [x] Unicode property pattern の implicit `FIXEDENCODING` と cross-encoding input の拒否を一致させる。
- [x] Unicode property pattern の source encoding と implicit `FIXEDENCODING` introspection を追加する。
- [x] /u、/e、/s は `Regexp.new` の options ではなく regex literal の表記であることを確認し、Onibi の文字列 pattern API の対象外として明記する。
- 全 encoding matrix と encoding mode の発生条件を揃える。
- [x] acceptance: Ruby 4.0.6 の代表的な encoding matrix を `fixtures/regexp_encoding_matrix.yml` に fixture 化する。

### REGEXP-009 — mode と source preprocessing を実装する

- Priority: P1
- Dependencies: REGEXP-002, REGEXP-007
- [x] extended mode x の whitespace/comment 処理を lexer 前処理として追加する。
- [x] extended mode の escaped whitespace と escaped `#` を literal として処理する。
- [x] (?#comment) を追加する。
- [x] inline modifier prefix `(?i)` / `(?-i)` を追加する。
- [x] inline modifier prefix `(?m)` / `(?-m)` を既存の multiline option に接続する。
- [x] inline modifier prefix `(?x)` / `(?-x)` を既存の extended preprocessing に接続する。
- [x] combined inline modifier `(?imx)` / `(?-imx)` の基本option更新を追加する。
- [x] inline modifier `(?i:...)` を全体 wrapper として追加する。
- [x] scoped multiline modifier `(?m:...)` / `(?-m:...)` を option AST と matcher state に接続する。
- [x] positive scoped extended mode `(?x:...)` の whitespace/comment 処理を lexer scanner に接続する。
- [x] negative scoped extended mode `(?-x:...)` の lexer state stack を実装する。
- [x] scoped combined i/m/x modes (`(?im:...)`、`(?-im:...)`、`(?imx:...)`) を実装する。
- [x] nested positive/negative extended scopes で、無効化された scope の whitespace/comment を保持する。
- [x] inline modifier を複合 pattern 内の scope 付き option AST にする。
- Ruby literal interpolation 自体は文字列 API の範囲外として維持するか、別 API の要否を決める。
- acceptance: mode の on/off scope と comment/whitespace の parse/match を比較する。

### REGEXP-010 — Regexp public API を拡張する

- Priority: P1
- Dependencies: REGEXP-001, REGEXP-008, REGEXP-009
- constructor の Ruby 互換 flags、Regexp 引数、keyword timeout を追加する。
- source、encoding、fixed_encoding?、casefold?、==、eql?、hash、inspect、to_s を追加する。
- [x] source と casefold? の基本 introspection を追加する。
- [x] ASCII-only non-fixed pattern の `Regexp#source` encoding を US-ASCII に揃える。
- [x] `==`、`eql?`、`hash` の基本 object semantics を追加する。
- [x] 基本的な `inspect` / `to_s` formatting を追加する。
- [x] `to_s` / `inspect` の Ruby mode flag order（`mix`）を追加する。
- [x] `Regexp#inspect` の `NOENCODING` suffix（`n`）を追加する。
- [x] 既存 `Onibi::Regexp` を `new` / `compile` に渡す基本コピーを追加する。
- [x] MRI `Regexp` を `new` / `compile` に渡す source/options ベースの基本コピーを追加する。
- [x] Regexp#=~、===、unary ~ を追加する。offset 引数は未対応のまま。
- [x] `Regexp::EXTENDED` integer flag を既存の extended mode に接続する。
- [x] `Regexp#options` を全constructor形式で整数bitmaskとして返す。
- [x] `Regexp.linear_time?` の保守的な危険構文判定を追加する。
- [x] `Regexp.timeout` / `timeout=` と constructor timeout keywordの基本設定を追加する。
- [x] Onibi Regexp copy時のtimeout保持とconstructor/compile overrideを追加する。
- Regexp.escape、Regexp.union、Regexp.last_match を追加する。
- [x] `Regexp.escape` と文字列 alternatives / 空集合の `Regexp.union` を追加する。Regexp 引数や全オプション互換は未対応。
- [x] `Regexp.escape` のSymbol、`to_str`、非変換値TypeErrorをRuby互換に近づける。
- [x] `Regexp.escape` の hyphen と control whitespace（`\\t`、`\\n`、`\\v`、`\\f`、`\\r`）をRuby形式に揃える。
- [x] `Regexp.escape` の ASCII-only result encoding を US-ASCII に揃える。
- [x] `Regexp.quote` を `Regexp.escape` の alias として追加する。
- [x] `Regexp.try_convert` の self / `to_regexp` / nil / TypeError contract を追加する。
- [x] `Regexp#names` と `Regexp#named_captures` の基本取得、および duplicate named group の index 集約を追加する。
- [x] 実装済みの `Regexp#to_s` / `inspect` を public RBS に反映する。
- [x] `Regexp.union` がMRI/Onibiのcompiled patternをsource alternativeとして受け取り、compiled pattern の ignorecase scope を保持する基本対応を追加する。
- [x] `Regexp.union` がcompiled pattern の multiline / extended scope と複合 option を保持する基本対応を追加する。
- [x] `Regexp.union` がcompiled pattern の `FIXEDENCODING` / `NOENCODING` を保持する基本対応を追加する。
- [x] `Regexp.union` が string alternative 追加時に `NOENCODING` を MRI の encoding option semantics に合わせて再計算する。
- [x] `Regexp#match` / `match?` の position 引数を実装し、負数・Float coercion・範囲外を処理する。
- [x] global match variables は設計スコープ外とし、Onibi の明示的な match API が global state を変更しないことを維持する。
- [x] public API inventory は MRI 4.0.6 の実装可能な全メソッドを比較し、global match state の `last_match` は設計スコープ外として明記する。

### REGEXP-011 — timeout、linear-time 判定、ReDoS 制御を追加する

- Priority: P2
- Dependencies: REGEXP-007, REGEXP-010
- class/instance timeout と timeout error を追加する。
- [x] class/instance timeout の 0 および負値を拒否する。
- [x] timeout 発生時に `Regexp::TimeoutError` 相当の専用例外を返す。
- [x] Regexp.linear_time? 相当の保守的な安全性判定（backreference、lookaround、atomic group、absence operator）を追加する。
- NFA/DFA のメモリ上限、実行ステップ上限、割り込み・キャンセル方針を整理する。
- backreference/lookaround/atomic group を含む危険パターンの安全性を differential/property test する。

### REGEXP-012 — MatchData の完全な Ruby API と統合を追加する

- Priority: P2
- Dependencies: REGEXP-001, REGEXP-010
- bytebegin、byteend、byteoffset、match_length、pre_match、post_match、string、regexp、names、named_captures、values_at を追加する。
- [x] `MatchData#values_at` の integer/range 基本抽出を追加する。
- [x] `MatchData#string`、`regexp`、`pre_match`、`post_match` の match context を追加する。
- [x] `MatchData#names` と `named_captures` の基本取得を追加する。
- [x] `MatchData#bytebegin`、`byteend`、`byteoffset`、`match_length` の基本取得を追加する。
- [x] offset系APIのnamed index、負数・範囲外・型エラーをRuby互換に近づける。
- [x] unmatched capture の `offset` を `[nil, nil]` として返す。
- [x] `MatchData#[]` / `values_at` のFloat coercionと未知named capture errorを追加する。
- [x] `MatchData#[]` / `values_at` の負数 index を capture-only range として処理する。
- [x] `MatchData#values_at` の負数 range bound と exclusive end をRuby semanticsに揃える。
- [x] `MatchData#[]` / `values_at` の string/symbol named index を追加する。
- [x] `MatchData#match` の index/name value lookup を追加する。
- [x] `MatchData#to_s` と named capture を含む基本 `inspect` を追加する。
- [x] `MatchData#inspect` の Ruby class name formatting（`#<MatchData ...>`）を追加する。
- [x] `MatchData#==`、`eql?`、`hash` の基本 value semantics を追加する。
- [x] `MatchData#deconstruct`、`deconstruct_keys` の positional/named capture 分解を追加する。
- [x] `deconstruct` から full match を除外し、`deconstruct_keys` を Symbol-keyed Ruby semantics に揃える。
- String/Symbol の match、match?、scan、gsub、sub 統合を、v1 non-goal の解除判断とともに設計する。
- acceptance: Ruby 4.0.6 MatchData メソッド一覧を網羅する。

## 参照資料

- [Ruby 4.0.6 Regexp class documentation](https://docs.ruby-lang.org/en/4.0/Regexp.html)
- [Ruby 4.0.6 MatchData class documentation](https://docs.ruby-lang.org/en/4.0/MatchData.html)
- [Onibi design](onibi-design.md)
- [Core MVP task list](core-mvp-task-list.md)

Ruby 4.0.6 の公式資料では、Regexp の構文として special characters、source literals、character classes、shorthand classes、anchors、alternation、quantifiers、groups/captures、Unicode、POSIX bracket expressions、comments を扱い、さらに modes、encodings、timeouts、linear-time optimization、公開 API を定義している。本表はそれらを Onibi の実装単位に分解したものである。
