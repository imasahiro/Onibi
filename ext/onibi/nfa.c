/*
 * NFA module boundary.
 *
 * Onibi lowers the tagged epsilon-NFA directly while it builds GIR.  The
 * boundary is explicit so a standalone NFA builder can be added without
 * changing the VM modules.
 */
