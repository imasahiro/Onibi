#ifndef ONIBI_AST_INTERNAL_H
#define ONIBI_AST_INTERNAL_H

#include "ruby.h"

#include <stdint.h>

/* Private AST contract.
 *
 * Tokenization, parsing, and semantic analysis exchange C-owned records.
 * Ruby values are accepted only at the parser boundary.  The definitions
 * remain in the amalgamated implementation until the modules become
 * independent translation units.
 */

#define ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS (1U << 0)
#define ONIBI_AST_FLAG_ANCHOR_REPEAT (1U << 1)
#define ONIBI_AST_FLAG_NULLABLE_ABSENCE (1U << 2)
#define ONIBI_AST_FLAG_NULLABLE_CAPTURE (1U << 3)

#define ONIBI_AST_ANALYSIS_HAS_CAPTURE (1U << 0)
#define ONIBI_AST_ANALYSIS_NULLABLE_CAPTURE (1U << 1)
#define ONIBI_AST_ANALYSIS_NULLABLE_ABSENCE (1U << 2)
#define ONIBI_AST_ANALYSIS_HAS_ANCHOR (1U << 3)
#define ONIBI_AST_ANALYSIS_ANCHOR_REPEAT (1U << 4)

typedef struct OnibiTokenVector OnibiTokenVector;
typedef struct OnibiParsed OnibiParsed;
typedef struct OnibiAstAnalysis OnibiAstAnalysis;
typedef struct OnibiAstArena OnibiAstArena;
typedef uint32_t OnibiAstId;

static void onibi_tokenize_internal(VALUE source, int extended,
				    OnibiTokenVector *tokens);
static VALUE onibi_parser_parse_internal(VALUE source, VALUE options,
					 const OnibiTokenVector *tokens);
static OnibiParsed *onibi_parsed_get(VALUE value);
static int onibi_ast_safe_multibyte_class(const OnibiAstArena *arena,
					  OnibiAstId id);
static int onibi_ast_nullable_scan(const OnibiAstArena *arena, OnibiAstId id,
				   OnibiAstAnalysis *analysis);

#endif
