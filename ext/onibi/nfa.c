/* Tagged epsilon-NFA intermediate representation. */
typedef struct {
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    OnibiIdVector starts;
    long accept;
} OnibiTaggedNfa;

static void
onibi_nfa_init(OnibiTaggedNfa *nfa)
{
    memset(nfa, 0, sizeof(*nfa));
    onibi_gir_state_vector_init(&nfa->states);
    onibi_gir_edge_vector_init(&nfa->edges);
    onibi_id_vector_init(&nfa->starts);
    nfa->accept = -1;
}

static void
onibi_nfa_free(OnibiTaggedNfa *nfa)
{
    onibi_gir_state_vector_free(&nfa->states);
    onibi_gir_edge_vector_free(&nfa->edges);
    onibi_id_vector_free(&nfa->starts);
    nfa->accept = -1;
}

/* Publish the ordered epsilon-path records as GIR. */
static void
onibi_epsilon_eliminate(OnibiTaggedNfa *nfa, onibi_gir_builder_t *gir)
{
    onibi_gir_state_vector_free(&gir->states);
    onibi_gir_edge_vector_free(&gir->edges);
    gir->states = nfa->states;
    gir->edges = nfa->edges;
    onibi_gir_state_vector_init(&nfa->states);
    onibi_gir_edge_vector_init(&nfa->edges);
}
