/* Tagged epsilon-NFA intermediate representation. */
typedef enum {
    ONIBI_NFA_EPSILON = 0,
    ONIBI_NFA_CONSUME = 1
} OnibiNfaTransitionKind;
typedef long OnibiNfaStateId;
/* A slice is owned by its NFA edge.  The vector type is shared with GIR so
   action ordering has one representation across both intermediate forms. */
typedef OnibiGActionVector OnibiActionSlice;
typedef struct {
    OnibiNfaStateId from;
    OnibiNfaStateId to;
    OnibiNfaTransitionKind kind;
    OnibiActionSlice actions;
} OnibiNfaEdge;
typedef ONIBI_VECTOR(OnibiNfaEdge) OnibiNfaEdgeVector;
typedef struct {
    OnibiGirStateVector states;
    OnibiNfaEdgeVector edges;
    OnibiIdVector starts;
    long accept;
} OnibiTaggedNfa;

ONIBI_VECTOR_DEFINE(onibi_nfa_edge_vector, OnibiNfaEdgeVector, OnibiNfaEdge, 8,
		    "NFA edge vector is too large")

static void
onibi_nfa_init(OnibiTaggedNfa *nfa)
{
    memset(nfa, 0, sizeof(*nfa));
    onibi_gir_state_vector_init(&nfa->states);
    onibi_nfa_edge_vector_init(&nfa->edges);
    onibi_id_vector_init(&nfa->starts);
    nfa->accept = -1;
}

static void
onibi_nfa_free(OnibiTaggedNfa *nfa)
{
    onibi_gir_state_vector_free(&nfa->states);
    for (size_t i = 0; i < nfa->edges.count; i++)
	onibi_g_action_vector_free(&nfa->edges.entries[i].actions);
    ONIBI_VECTOR_RELEASE(nfa->edges.entries, nfa->edges.count,
			 nfa->edges.capacity);
    onibi_id_vector_free(&nfa->starts);
    nfa->accept = -1;
}

static int
onibi_nfa_actions_equal(const OnibiGActionVector *left,
			const OnibiGActionVector *right)
{
    return left->count == right->count &&
	   (left->count == 0 ||
	    memcmp(left->entries, right->entries,
		   left->count * sizeof(*left->entries)) == 0);
}

static int
onibi_nfa_edge_seen(const OnibiGirEdgeVector *edges, long from, long to,
		    const OnibiGActionVector *actions)
{
    for (size_t i = 0; i < edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &edges->entries[i];
	if (edge->from == from && edge->to == to &&
	    onibi_nfa_actions_equal(&edge->actions, actions))
	    return 1;
    }
    return 0;
}

typedef struct {
    const OnibiTaggedNfa *nfa;
    OnibiGirEdgeVector *out;
    unsigned char *visiting;
    long state_count;
} onibi_nfa_closure_t;

/* Traverse ordered epsilon paths and emit the first consuming edge. */
static void
onibi_nfa_emit_closure(onibi_nfa_closure_t *closure, long origin, long state,
		       const OnibiGActionVector *actions)
{
    for (size_t i = 0; i < closure->nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &closure->nfa->edges.entries[i];
	if (edge->from != state || edge->kind != ONIBI_NFA_EPSILON) continue;
	if (edge->to < 0 || edge->to >= closure->state_count)
	    rb_raise(rb_eArgError, "NFA epsilon destination is out of range");
	if (closure->visiting[edge->to])
	    rb_raise(eRegexpError, "epsilon transition cycle");
	closure->visiting[edge->to] = 1;
	OnibiGActionVector next =
	    onibi_g_action_vector_concat(actions, &edge->actions);
	onibi_nfa_emit_closure(closure, origin, edge->to, &next);
	onibi_g_action_vector_free(&next);
	closure->visiting[edge->to] = 0;
    }
    for (size_t i = 0; i < closure->nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &closure->nfa->edges.entries[i];
	if (edge->from != state || edge->kind != ONIBI_NFA_CONSUME) continue;
	OnibiGActionVector combined =
	    onibi_g_action_vector_concat(actions, &edge->actions);
	if (!onibi_nfa_edge_seen(closure->out, origin, edge->to, &combined))
	    onibi_gir_edge_vector_push(
		closure->out,
		(OnibiGirEdgeEntry){origin, edge->to, 0, combined});
	else
	    onibi_g_action_vector_free(&combined);
    }
}

/* Publish GIR after ordered epsilon closure. */
static void
onibi_epsilon_eliminate(OnibiTaggedNfa *nfa, onibi_gir_builder_t *gir)
{
    OnibiGirEdgeVector result;
    onibi_gir_edge_vector_init(&result);
    long state_count = (long)nfa->states.count;
    unsigned char *visiting =
	state_count ? ALLOC_N(unsigned char, state_count) : NULL;
    if (visiting) memset(visiting, 0, (size_t)state_count);
    onibi_nfa_closure_t closure = {nfa, &result, visiting, state_count};
    for (size_t i = 0; i < nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &nfa->edges.entries[i];
	if (edge->kind == ONIBI_NFA_CONSUME) {
	    if (!onibi_nfa_edge_seen(&result, edge->from, edge->to,
				     &edge->actions))
		onibi_gir_edge_vector_push(
		    &result, (OnibiGirEdgeEntry){
				 edge->from, edge->to, 0,
				 onibi_g_action_vector_copy(&edge->actions)});
	}
	else {
	    if (edge->to < 0 || edge->to >= state_count)
		rb_raise(rb_eArgError,
			 "NFA epsilon destination is out of range");
	    visiting[edge->to] = 1;
	    onibi_nfa_emit_closure(&closure, edge->from, edge->to,
				   &edge->actions);
	    visiting[edge->to] = 0;
	}
    }
    if (visiting) xfree(visiting);
    onibi_gir_state_vector_free(&gir->states);
    onibi_gir_edge_vector_free(&gir->edges);
    gir->states = nfa->states;
    gir->edges = result;
    onibi_gir_state_vector_init(&nfa->states);
}
