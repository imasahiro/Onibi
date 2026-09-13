#ifndef ONIBI_VECTOR_H
#define ONIBI_VECTOR_H

/* Vector allocation and invariant errors use the Ruby extension API. */
#include "ruby.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct onibi_allocation_owner onibi_allocation_owner_t;

static void *onibi_owned_realloc(onibi_allocation_owner_t *owner, void *pointer,
				 size_t size);
static void onibi_owned_free(onibi_allocation_owner_t *owner, void *pointer);
static int onibi_owned_pointer_p(onibi_allocation_owner_t *owner,
				 void *pointer);
static void onibi_owned_transfer(onibi_allocation_owner_t *owner,
				 void *pointer);

/* Return 1 when the complete source range is inside destination storage, 0
 * when the ranges do not overlap, and -1 for a partial overlap or overflow.
 * Use integer addresses here.  Relational comparisons between pointers to
 * different objects have undefined behavior in C. */
static inline int
onibi_vector_alias_offset(const void *destination, size_t capacity,
			  size_t element_size, const void *source,
			  size_t source_count, size_t *offset)
{
    if (source_count == 0 || !destination || !source) return 0;
    if (element_size == 0 || capacity > SIZE_MAX / element_size ||
	source_count > SIZE_MAX / element_size)
	return -1;

    size_t destination_bytes = capacity * element_size;
    size_t source_bytes = source_count * element_size;
    uintptr_t destination_address = (uintptr_t)destination;
    uintptr_t source_address = (uintptr_t)source;
    if (source_address < destination_address) return 0;
    uintptr_t byte_offset = source_address - destination_address;
    if (byte_offset >= destination_bytes || byte_offset > SIZE_MAX) return 0;
    size_t offset_value = (size_t)byte_offset;
    if (source_bytes > destination_bytes - offset_value) return -1;
    *offset = offset_value;
    return 1;
}

/* A vector owns its contiguous entry storage.  Vector operations copy entry
 * values only.  Resources referenced by an entry remain caller-owned, and
 * the caller must release them before ONIBI_VECTOR_RELEASE. */
#define ONIBI_VECTOR(Type)                                                     \
    struct {                                                                   \
	Type *entries;                                                         \
	size_t count;                                                          \
	size_t capacity;                                                       \
	onibi_allocation_owner_t *allocation_owner;                            \
    }

static inline int
onibi_vector_next_capacity(size_t count, size_t capacity, size_t additional,
			   size_t element_size, size_t initial_capacity,
			   size_t *result)
{
    if (element_size == 0 || initial_capacity == 0 ||
	additional > SIZE_MAX - count)
	return 0;
    size_t required = count + additional;
    if (required <= capacity) {
	*result = capacity;
	return 1;
    }
    if (required > SIZE_MAX / element_size) return 0;

    size_t next = capacity == 0 ? initial_capacity : capacity;
    while (next < required) {
	if (next > SIZE_MAX / 2) {
	    next = required;
	    break;
	}
	next *= 2;
    }
    if (next > SIZE_MAX / element_size) return 0;
    *result = next;
    return 1;
}

#define ONIBI_VECTOR_INIT(Data, Count, Capacity)                               \
    do {                                                                       \
	(Data) = NULL;                                                         \
	(Count) = 0;                                                           \
	(Capacity) = 0;                                                        \
    } while (0)

#define ONIBI_VECTOR_RESERVE(Data, Count, Capacity, Type, Additional, Initial, \
			     Error)                                            \
    do {                                                                       \
	size_t onibi_vector_next_;                                             \
	if (!onibi_vector_next_capacity((Count), (Capacity), (Additional),     \
					sizeof(Type), (Initial),               \
					&onibi_vector_next_))                  \
	    rb_raise(rb_eNoMemError, "%s", (Error));                           \
	if (onibi_vector_next_ != (Capacity)) {                                \
	    (Data) = REALLOC_N((Data), Type, onibi_vector_next_);              \
	    (Capacity) = onibi_vector_next_;                                   \
	}                                                                      \
    } while (0)

#define ONIBI_VECTOR_PUSH(Data, Count, Capacity, Type, Value, Initial, Error)  \
    do {                                                                       \
	ONIBI_VECTOR_RESERVE((Data), (Count), (Capacity), Type, 1, (Initial),  \
			     (Error));                                         \
	(Data)[(Count)++] = (Value);                                           \
    } while (0)

#define ONIBI_VECTOR_APPEND(Data, Count, Capacity, Type, SourceData,           \
			    SourceCount, Initial, Error)                       \
    do {                                                                       \
	size_t onibi_vector_source_count_ = (SourceCount);                     \
	const Type *onibi_vector_source_data_ = NULL;                          \
	size_t onibi_vector_source_offset_ = 0;                                \
	int onibi_vector_source_alias_ = 0;                                    \
	if (onibi_vector_source_count_ != 0) {                                 \
	    onibi_vector_source_data_ = (SourceData);                          \
	    onibi_vector_source_alias_ = onibi_vector_alias_offset(            \
		(Data), (Capacity), sizeof(Type), onibi_vector_source_data_,   \
		onibi_vector_source_count_, &onibi_vector_source_offset_);     \
	    if (onibi_vector_source_alias_ < 0)                                \
		rb_raise(rb_eRuntimeError,                                     \
			 "vector append source overlaps destination storage"); \
	}                                                                      \
	ONIBI_VECTOR_RESERVE((Data), (Count), (Capacity), Type,                \
			     onibi_vector_source_count_, (Initial), (Error));  \
	if (onibi_vector_source_alias_ > 0)                                    \
	    onibi_vector_source_data_ =                                        \
		(const Type *)((const unsigned char *)(Data) +                 \
			       onibi_vector_source_offset_);                   \
	if (onibi_vector_source_count_ != 0)                                   \
	    memmove((Data) + (Count), onibi_vector_source_data_,               \
		    onibi_vector_source_count_ * sizeof(Type));                \
	(Count) += onibi_vector_source_count_;                                 \
    } while (0)

#define ONIBI_VECTOR_INSERT(Data, Count, Capacity, Type, Index, Value,         \
			    Initial, Error)                                    \
    do {                                                                       \
	size_t onibi_vector_index_ = (Index);                                  \
	if (onibi_vector_index_ > (Count))                                     \
	    rb_raise(rb_eArgError, "vector insert index is out of range");     \
	ONIBI_VECTOR_RESERVE((Data), (Count), (Capacity), Type, 1, (Initial),  \
			     (Error));                                         \
	memmove((Data) + onibi_vector_index_ + 1,                              \
		(Data) + onibi_vector_index_,                                  \
		((Count) - onibi_vector_index_) * sizeof(Type));               \
	(Data)[onibi_vector_index_] = (Value);                                 \
	(Count)++;                                                             \
    } while (0)

#define ONIBI_VECTOR_RELEASE(Data, Count, Capacity)                            \
    do {                                                                       \
	xfree(Data);                                                           \
	(Data) = NULL;                                                         \
	(Count) = 0;                                                           \
	(Capacity) = 0;                                                        \
    } while (0)

#define ONIBI_OWNED_VECTOR_RESERVE(Vector, Type, Additional, Initial, Error)   \
    do {                                                                       \
	size_t onibi_vector_next_;                                             \
	if (!onibi_vector_next_capacity((Vector)->count, (Vector)->capacity,   \
					(Additional), sizeof(Type), (Initial), \
					&onibi_vector_next_))                  \
	    rb_raise(rb_eNoMemError, "%s", (Error));                           \
	if (onibi_vector_next_ != (Vector)->capacity) {                        \
	    (Vector)->entries = onibi_owned_realloc(                           \
		(Vector)->allocation_owner, (Vector)->entries,                 \
		onibi_vector_next_ * sizeof(Type));                            \
	    (Vector)->capacity = onibi_vector_next_;                           \
	}                                                                      \
    } while (0)

#define ONIBI_OWNED_VECTOR_PUSH(Vector, Type, Value, Initial, Error)           \
    do {                                                                       \
	ONIBI_OWNED_VECTOR_RESERVE((Vector), Type, 1, (Initial), (Error));     \
	(Vector)->entries[(Vector)->count++] = (Value);                        \
    } while (0)

#define ONIBI_OWNED_VECTOR_APPEND(Destination, Type, SourceData, SourceCount,  \
				  Initial, Error)                              \
    do {                                                                       \
	size_t onibi_vector_source_count_ = (SourceCount);                     \
	const Type *onibi_vector_source_data_ = NULL;                          \
	size_t onibi_vector_source_offset_ = 0;                                \
	int onibi_vector_source_alias_ = 0;                                    \
	if (onibi_vector_source_count_ != 0) {                                 \
	    onibi_vector_source_data_ = (SourceData);                          \
	    onibi_vector_source_alias_ = onibi_vector_alias_offset(            \
		(Destination)->entries, (Destination)->capacity, sizeof(Type), \
		onibi_vector_source_data_, onibi_vector_source_count_,         \
		&onibi_vector_source_offset_);                                 \
	    if (onibi_vector_source_alias_ < 0)                                \
		rb_raise(rb_eRuntimeError,                                     \
			 "vector append source overlaps destination storage"); \
	}                                                                      \
	ONIBI_OWNED_VECTOR_RESERVE((Destination), Type,                        \
				   onibi_vector_source_count_, (Initial),      \
				   (Error));                                   \
	if (onibi_vector_source_alias_ > 0)                                    \
	    onibi_vector_source_data_ =                                        \
		(const Type *)((const unsigned char *)(Destination)->entries + \
			       onibi_vector_source_offset_);                   \
	if (onibi_vector_source_count_ != 0)                                   \
	    memmove((Destination)->entries + (Destination)->count,             \
		    onibi_vector_source_data_,                                 \
		    onibi_vector_source_count_ * sizeof(Type));                \
	(Destination)->count += onibi_vector_source_count_;                    \
    } while (0)

#define ONIBI_OWNED_VECTOR_INSERT(Vector, Type, Index, Value, Initial, Error)  \
    do {                                                                       \
	size_t onibi_vector_index_ = (Index);                                  \
	if (onibi_vector_index_ > (Vector)->count)                             \
	    rb_raise(rb_eArgError, "vector insert index is out of range");     \
	ONIBI_OWNED_VECTOR_RESERVE((Vector), Type, 1, (Initial), (Error));     \
	memmove((Vector)->entries + onibi_vector_index_ + 1,                   \
		(Vector)->entries + onibi_vector_index_,                       \
		((Vector)->count - onibi_vector_index_) * sizeof(Type));       \
	(Vector)->entries[onibi_vector_index_] = (Value);                      \
	(Vector)->count++;                                                     \
    } while (0)

#define ONIBI_OWNED_VECTOR_RELEASE(Vector)                                     \
    do {                                                                       \
	onibi_owned_free((Vector)->allocation_owner, (Vector)->entries);       \
	(Vector)->entries = NULL;                                              \
	(Vector)->count = 0;                                                   \
	(Vector)->capacity = 0;                                                \
    } while (0)

/* Generate the standard operations for a vector with entries, count, and
 * capacity fields.  Keep a custom free function when elements own memory. */
#define ONIBI_VECTOR_DEFINE(Prefix, VectorType, Type, Initial, Error)          \
    static inline void Prefix##_init(VectorType *vector)                       \
    {                                                                          \
	ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);   \
	vector->allocation_owner = NULL;                                       \
    }                                                                          \
    static inline void Prefix##_bind(VectorType *vector,                       \
				     onibi_allocation_owner_t *owner)          \
    {                                                                          \
	vector->allocation_owner = owner;                                      \
    }                                                                          \
    static inline void Prefix##_reserve(VectorType *vector, size_t additional) \
    {                                                                          \
	ONIBI_OWNED_VECTOR_RESERVE(vector, Type, additional, Initial, Error);  \
    }                                                                          \
    static inline void Prefix##_push(VectorType *vector, Type value)           \
    {                                                                          \
	ONIBI_OWNED_VECTOR_PUSH(vector, Type, value, Initial, Error);          \
    }                                                                          \
    static inline void Prefix##_append(VectorType *destination,                \
				       const VectorType *source)               \
    {                                                                          \
	ONIBI_OWNED_VECTOR_APPEND(destination, Type, source->entries,          \
				  source->count, Initial, Error);              \
    }                                                                          \
    static inline void Prefix##_free(VectorType *vector)                       \
    {                                                                          \
	ONIBI_OWNED_VECTOR_RELEASE(vector);                                    \
    }

#endif
