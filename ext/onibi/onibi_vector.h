#ifndef ONIBI_VECTOR_H
#define ONIBI_VECTOR_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Declare a typed vector without generating one implementation for each
 * element type.  A vector owns its entries.  An element can own more memory,
 * but its caller must release that memory before ONIBI_VECTOR_RELEASE. */
#define ONIBI_VECTOR(Type)                                                     \
    struct {                                                                   \
	Type *entries;                                                         \
	size_t count;                                                          \
	size_t capacity;                                                       \
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
	ONIBI_VECTOR_RESERVE((Data), (Count), (Capacity), Type,                \
			     onibi_vector_source_count_, (Initial), (Error));  \
	if (onibi_vector_source_count_ != 0)                                   \
	    memmove((Data) + (Count), (SourceData),                            \
		    onibi_vector_source_count_ * sizeof(Type));                \
	(Count) += onibi_vector_source_count_;                                 \
    } while (0)

#define ONIBI_VECTOR_INSERT(Data, Count, Capacity, Type, Index, Value,         \
			    Initial, Error)                                    \
    do {                                                                       \
	size_t onibi_vector_index_ = (Index);                                  \
	if (onibi_vector_index_ > (Count)) onibi_vector_index_ = (Count);      \
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

/* Generate the standard operations for a vector with entries, count, and
 * capacity fields.  Keep a custom free function when elements own memory. */
#define ONIBI_VECTOR_DEFINE(Prefix, VectorType, Type, Initial, Error)          \
    static inline void Prefix##_init(VectorType *vector)                       \
    {                                                                          \
	ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);   \
    }                                                                          \
    static inline void Prefix##_reserve(VectorType *vector, size_t additional) \
    {                                                                          \
	ONIBI_VECTOR_RESERVE(vector->entries, vector->count, vector->capacity, \
			     Type, additional, Initial, Error);                \
    }                                                                          \
    static inline void Prefix##_push(VectorType *vector, Type value)           \
    {                                                                          \
	ONIBI_VECTOR_PUSH(vector->entries, vector->count, vector->capacity,    \
			  Type, value, Initial, Error);                        \
    }                                                                          \
    static inline void Prefix##_append(VectorType *destination,                \
				       const VectorType *source)               \
    {                                                                          \
	ONIBI_VECTOR_APPEND(destination->entries, destination->count,          \
			    destination->capacity, Type, source->entries,      \
			    source->count, Initial, Error);                    \
    }                                                                          \
    static inline void Prefix##_free(VectorType *vector)                       \
    {                                                                          \
	ONIBI_VECTOR_RELEASE(vector->entries, vector->count,                   \
			     vector->capacity);                                \
    }

#endif
