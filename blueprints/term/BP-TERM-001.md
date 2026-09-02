# BP-TERM-001 Term representation

Status: draft
Applies to: OTP-29.0.5 (erts-17.0.5)
Lesson: m02
Depends on: none
Conformance: CT-TERM-001

## 1. Scope

This specifies how a value is represented in one machine word: the tag layout that decides what a word holds, which values fit entirely in their own word and which need a heap object, the shape of every heap object the tag layout can name, the number of words each shape occupies, and the total order over all of them. It covers 64 bit and 32 bit word sizes, because the boundary between an integer that fits in a word and one that does not is the single constant that differs and a reimplementation that hardcodes the 64 bit figure is wrong on half the platforms.

It does not specify where the words come from. Heap layout, allocation, resizing, generational collection and the literal area are BP-GC-001. The internal representation of a map beyond its header word, and the switch between the flat and the hash array mapped trie forms, is BP-MAP-001. The atom table, its hashing, its limits and its interaction with distribution is BP-ATOM-001. Encoding a term for the wire is BP-DIST-001, which shares nothing with this specification except the set of things that need encoding. None of those four are written yet.

The boundary that matters most is with BP-GC-001. Everything in section 3 that builds a term takes heap words as given and is marked `[alloc]` where it needs them. What happens when the heap has none is not specified here, and a reimplementation cannot use this document alone to decide whether a construction can be interrupted.

## 2. Data structures

Every value in the system is one `Eterm`, which is one machine word. There is no second word of type information anywhere, no object header outside the heap, and no boxing of pointers. A word is either the value itself or the address of a heap object, and the bits that decide which are at the bottom of the word so that a mask and a compare answer the question.

The three tables below are generated from the emulator's own headers rather than typed out, because a table of tag values is exactly the kind of thing that stays correct in a document for two releases and then quietly stops.

### 2.1 Primary tags

<!-- bpc: primary-tags -->
Two bits, mask `0x3`, on every `Eterm`.

| Name | Bits | Value | What it means |
| --- | --- | --- | --- |
| `TAG_PRIMARY_HEADER` | `0b00` | 0 | The word is the first word of a boxed object and says what follows it. |
| `TAG_PRIMARY_LIST` | `0b01` | 1 | The rest of the word is the address of a two word cons cell. |
| `TAG_PRIMARY_BOXED` | `0b10` | 2 | The rest of the word is the address of a header word. |
| `TAG_PRIMARY_IMMED1` | `0b11` | 3 | The value is in the word itself. Four more bits say which kind. |
<!-- bpc: end primary-tags -->

Two of the four states are pointers and they are distinguished for one reason. A word tagged `TAG_PRIMARY_LIST` points at two words with no header in front of them, so a cons cell costs two words rather than three. A word tagged `TAG_PRIMARY_BOXED` points at a header word which says what kind of object follows and how large it is. Spending a quarter of a two bit tag space on a single data structure is what buys the saving, and it is paid once in the layout rather than once per cell.

### 2.2 Immediate tags

<!-- bpc: immediate-tags -->
4 bits, mask `0xF`, the low two of them `TAG_PRIMARY_IMMED1`.

| Name | Bits | What it means |
| --- | --- | --- |
| `_TAG_IMMED1_PID` | `0b0011` | A local process identifier. |
| `_TAG_IMMED1_PORT` | `0b0111` | A local port identifier. |
| `_TAG_IMMED1_IMMED2` | `0b1011` | Not a value. Two more bits say which kind. |
| `_TAG_IMMED1_SMALL` | `0b1111` | A signed integer that fits in the remaining bits. |

When those four bits are `_TAG_IMMED1_IMMED2`, two more make 6, mask `0x3F`.

| Name | Bits | What it means |
| --- | --- | --- |
| `_TAG_IMMED2_ATOM` | `0b001011` | An index into the atom table. |
| `_TAG_IMMED2_CATCH` | `0b011011` | A catch frame marker, only ever found on a stack. |
| `_TAG_IMMED2_NIL` | `0b111011` | The empty list, one value with a tag to itself. |
<!-- bpc: end immediate-tags -->

The widths are chosen against how much payload each kind needs. A small integer is the value most sensitive to width, so it stops at four bits and keeps the rest. An atom is an index into a table with a fixed ceiling and never needed the full width, so it can afford six. The empty list needs no payload at all, because there is exactly one of it, so the tag is the entire term.

`_TAG_IMMED2_CATCH` is not a term a program can hold. It appears on a process stack to mark a catch frame and never in a variable, a message or a heap object. A reimplementation that has a different exception mechanism does not need it and can leave that encoding unused.

### 2.3 Header subtags

<!-- bpc: header-subtags -->
6 bits, mask `0x3F`, the low two of them `TAG_PRIMARY_HEADER`. The arity or size lives above them, from bit 6 up.

| Name | Bits | Value | What it holds |
| --- | --- | --- | --- |
| `_TAG_HEADER_ARITYVAL` | `0b000000` | `0x00` | A tuple. The arity is in the rest of the header word. |
| `_TAG_HEADER_POS_BIG` | `0b001000` | `0x08` | A bignum, positive. |
| `_TAG_HEADER_NEG_BIG` | `0b001100` | `0x0C` | A bignum, negative. |
| `_TAG_HEADER_REF` | `0b010000` | `0x10` | A local reference. |
| `_TAG_HEADER_FUN` | `0b010100` | `0x14` | A fun, with its environment following the header. |
| `_TAG_HEADER_FLOAT` | `0b011000` | `0x18` | A double, in the words after the header. |
| `_TAG_HEADER_RECORD` | `0b011100` | `0x1C` | A record. |
| `_TAG_HEADER_HEAP_BITS` | `0b100000` | `0x20` | A bitstring whose bytes are on the process heap. |
| `_TAG_HEADER_SUB_BITS` | `0b100100` | `0x24` | A slice of another bitstring, held as an offset and a length. |
| `_TAG_HEADER_BIN_REF` | `0b101000` | `0x28` | A reference to bytes held off heap. |
| `_TAG_HEADER_MAP` | `0b101100` | `0x2C` | A map, either flat or a hash array mapped trie. |
| `_TAG_HEADER_EXTERNAL_PID` | `0b110000` | `0x30` | A process identifier belonging to another node. |
| `_TAG_HEADER_EXTERNAL_PORT` | `0b110100` | `0x34` | A port identifier belonging to another node. |
| `_TAG_HEADER_EXTERNAL_REF` | `0b111000` | `0x38` | A reference belonging to another node. |
<!-- bpc: end header-subtags -->

Fourteen of a possible sixteen subtags are in use. Subtag `0x1` has no definition and is free. Subtag `0xF` has no definition either and is not free, because `_EXTERNAL_TAG_MASK` is built on the assumption that the three external kinds occupy `0xC` through `0xE` and that `0xF` stays out of the way, so a reimplementation that puts something at `0xF` has to give up the single mask test for whether a term belongs to another node.

Three of the fourteen come in groups that a single mask can test. `POS_BIG` and `NEG_BIG` differ only in the bit at `_BIG_SIGN_BIT`, so testing for a bignum of either sign is one mask and one compare. `HEAP_BITS` and `SUB_BITS` are arranged the same way under `_BITSTRING_TAG_MASK`. `ARITYVAL` sits under `_TRANSPARENT_TAG_MASK` with the subtag one bit above it. Those groupings are load bearing and a reimplementation that assigns the subtags in a different order loses them.

### 2.4 Sizes

Every figure below is in words. `W` is the word size in bits, 64 or 32.

| Constant | 64 bit | 32 bit | Meaning |
| --- | --- | --- | --- |
| `SMALL_BITS` | 60 | 28 | Bits available to an integer that fits in its own word, including the sign. |
| `MAX_SMALL` | 2^59 - 1 | 2^27 - 1 | Largest integer that costs no heap. |
| `MIN_SMALL` | -2^59 | -2^27 | Smallest integer that costs no heap. |
| `MAX_ARITYVAL` | 2^24 - 1 | 2^24 - 1 | Largest tuple arity. Not derived from the word size. |
| `ERL_ONHEAP_BINARY_LIMIT` | 64 | 64 | Bytes. At or below this a bitstring's data goes on the process heap. A byte count, so it does not scale with the word. |
| Heap bitstring header | 2 | 2 | Words in front of a heap bitstring's data. There is no constant for it. It falls out of `sizeof(ErlHeapBits)/sizeof(Eterm) - 1`, the struct being a header word, a bit count and a one element flexible array. |
| `ERL_BIN_REF_SIZE` | 3 | 3 | Words in a `BinRef`, being a header, a pointer to the off heap `Binary` and a link into the process off heap list. |
| `ERL_SUB_BITS_SIZE` | 5 | 5 | Words in an `ErlSubBits`, being a header, a combined base pointer and flag field, a start offset, an end offset and the original term. |
| `ERL_REFC_BITS_SIZE` | 8 | 8 | Words on the process heap for a bitstring whose data is off heap, the sum of the two above. |

The word cost of every shape follows from those.

| Shape | Words | Note |
| --- | --- | --- |
| Any immediate | 0 | The word is the term. Nothing is on a heap. |
| The empty tuple | 0 | A global literal, outside every process heap. See section 5. |
| Cons cell | 2 | No header. A list of n elements is 2n words plus whatever the elements cost. |
| Tuple of arity n, n at least 1 | n + 1 | One header word carrying the arity, then n element words. |
| Float | 1 + 64/W | Header plus the double. Two words on a 64 bit build, three on a 32 bit one. |
| Bignum of d digits | 1 + d | Header carrying the digit count and the sign in its subtag, then the digits. |
| Heap bitstring of b bits | 2 + ceil(b / W) | Two words of header, then the data rounded up to a whole number of words. |
| Off heap bitstring | 8 | Fixed, whatever the data length. The data is not on the process heap and is not counted. |

The last row is the one that surprises. A bitstring of exactly `ERL_ONHEAP_BINARY_LIMIT` bytes costs 10 words on a 64 bit build and one byte more costs 8, so the process heap cost of a bitstring is not monotonic in its length. A reimplementation is free to choose a different limit, and section 6 says which observables would move if it did.

## 3. Algorithms

The dialect is in NOTATION.md. Word sized quantities are in words throughout.

### 3.1 Classify a term

Every operation that has to know what it is holding starts here. The cost of the common case is one mask and one compare, which is the reason the layout is shaped the way it is.

```
 1. let P be `primary_tag(T)`, being the low two bits of T
 2. if P is `TAG_PRIMARY_LIST`
 3.     return cons
 4. if P is `TAG_PRIMARY_BOXED`
 5.     let H be the word at the address in T
 6.     if `primary_tag(H)` is not `TAG_PRIMARY_HEADER`
 7.         the heap is corrupt                     [fail]
 8.     return the boxed kind named by the six subtag bits of H
 9. if P is `TAG_PRIMARY_IMMED1`
10.     let I be the low four bits of T
11.     if I is not `_TAG_IMMED1_IMMED2`
12.         return the immediate kind named by I
13.     return the immediate kind named by the low six bits of T
14. the word is a header read as if it were a value, which is a defect
```

Step 14 is not reachable in a correct emulator. A header word only ever appears on a heap as the first word of a boxed object, and every path that reads one arrives through step 5 already knowing that. A reimplementation should make step 14 abort rather than return a value, because every way of reaching it is a bug that will otherwise produce a wrong answer somewhere far away.

Step 6 is a debug build check in ERTS rather than a release build one. A reimplementation may do the same. What it may not do is treat the check as optional in the sense of leaving the behaviour undefined when it fails, because section 4 states the invariant that makes step 5 safe and a reimplementation that does not maintain it will not work.

### 3.2 Decide whether an integer is a small

```
1. if V < `MIN_SMALL` or V > `MAX_SMALL`
2.     return false
3. return true
```

`MIN_SMALL` and `MAX_SMALL` come from `SMALL_BITS`, which is the word size minus four. The four are the immediate tag from section 2.2, and the sign is taken out of the remaining 60 rather than added to them, so the range is symmetric about zero in the way two's complement is symmetric and not one value wider on the positive side.

### 3.3 Build an integer

```
1. if the value fits by 3.2
2.     return (V shifted left by 4) with `_TAG_IMMED1_SMALL` in the low four bits
3. let d be the number of digits the value needs
4. reserve d + 1 words on the heap                  [alloc]
5. write a header with arity d and subtag `POS_BIG` or `NEG_BIG` by the sign
6. write the digits, least significant first
7. return the header address tagged `TAG_PRIMARY_BOXED`
```

Step 2 shifts the signed value left as if it were unsigned and recovers it with an arithmetic shift right on the way out. That is the whole of small integer arithmetic support: a value in this form can be added to another one by adding the words and subtracting one tag, which is why the tag is at the bottom rather than the top.

Every arithmetic operation that produces an integer runs this algorithm on its result, so a value that fits is always in the form of step 2 and never in the form of step 7. That is stated as an invariant in section 4 and it is what makes equality on integers a word comparison.

### 3.4 Build a tuple of arity n

```
1. if n is 0
2.     return `ERTS_GLOBAL_LIT_EMPTY_TUPLE`
3. if n > `MAX_ARITYVAL`
4.     fail badarg                                  [fail]
5. reserve n + 1 words on the heap                  [alloc]
6. write a header with arity n and subtag `ARITYVAL` into word 0
7. for each i in 0 to n - 1
8.     write element i into word i + 1
9. return the address of word 0 tagged `TAG_PRIMARY_BOXED`
```

Step 1 is not an optimisation and skipping it is not a performance choice. Section 5 says what breaks.

### 3.5 Build a bitstring of b bits

```
 1. if b is at most `ERL_ONHEAP_BITS_LIMIT`
 2.     reserve 2 + ceil(b / W) words on the heap   [alloc]
 3.     write a header with subtag `HEAP_BITS` and the word count
 4.     write b into the second word
 5.     copy the data into the words after it
 6.     return the header address tagged `TAG_PRIMARY_BOXED`
 7. allocate a reference counted `Binary` off the process heap, holding the data
 8. reserve `ERL_REFC_BITS_SIZE` words on the heap  [alloc]
 9. write a `BinRef` of `ERL_BIN_REF_SIZE` words pointing at the `Binary`
10. link the `BinRef` into the process off heap list
11. write an `ErlSubBits` of `ERL_SUB_BITS_SIZE` words, start 0, end b, original the `BinRef`
12. return the `ErlSubBits` address tagged `TAG_PRIMARY_BOXED`
```

Step 10 is the step a reimplementation is most likely to forget, and forgetting it leaks. The `BinRef` holds a reference count on the `Binary` and the process off heap list is how that count is released when the term becomes garbage. A `BinRef` written at step 9 and not linked at step 10 is a term that works perfectly and never frees anything.

Taking a slice of an existing bitstring is not this algorithm. A slice at or below the limit is copied out through steps 1 to 6 and does not hold a reference to the original, which is why a small piece of a large binary does not keep the large one alive. A slice above the limit is a new `ErlSubBits` sharing the existing `BinRef`, with the count bumped, and costs `ERL_SUB_BITS_SIZE` words rather than `ERL_REFC_BITS_SIZE`.

### 3.6 Count the words a term occupies

```
1. total := 0
2. for each word W reached from T, depth first, entering each occurrence separately
3.     if W is immediate, or W is the global empty tuple
4.         add nothing
5.     else if W is a cons
6.         add 2, then continue into the head and the tail
7.     else
8.         add the word count the header declares, then continue into each term slot
9. return total
```

Step 2 says "each occurrence separately" and that is the whole difference between the two observables in section 6. A term where the same subterm appears twice is counted twice here, because this algorithm answers the question "how many words would a copy of this take", and a copy has no sharing. An algorithm that instead marks what it has seen answers "how many words does this occupy right now", which is a smaller number and a different question.

Step 3 has to name the global empty tuple explicitly. It is boxed, so step 7 would otherwise reach it and count its header, and the header is not on the process heap.

### 3.7 Compare two terms in the standard order

```
 1. if A and B are the same word, return equal
 2. let a_kind and b_kind be the type numbers of A and B
 3. if a_kind is b_kind
 4.     compare within the type and return the result
 5. if A and B are both numbers
 6.     compare by value, converting the less precise one, and return the result
 7. return the sign of (b_kind - a_kind)
```

Step 7 is the line a reimplementation gets backwards. The subtraction is `b` minus `a`, so a positive result means A is the greater term, which means a **smaller** type number sorts **later**. The type numbers run from bitstring at `0x00` up to small integer at `0x10`, and the resulting order runs the other way: number, atom, reference, fun, port, pid, tuple, map, nil, list, bitstring. A reimplementation that assigns its own type numbers in the order it wants terms to sort, and then subtracts them the natural way round, produces exactly the reverse of the language's order and will pass no test that sorts anything.

Step 5 is the exception that keeps arithmetic sane. An integer and a float with the same value are neither less than nor greater than each other, so they are not ordered by their type numbers even though those numbers differ. Section 4 says what follows from that, and it is not what most readers assume.

Step 4 for the compound types is recursive and the recursion order is part of the language. Tuples compare by arity first and then element by element. Lists compare element by element and a shorter list that is a prefix of a longer one is the smaller. Maps compare by size first, then by keys in the standard order, then by values. Bitstrings compare byte by byte and then by any trailing bits.

## 4. Invariants, ordering guarantees and yield points

### Invariants

**INV-TERM-1.** Every `Eterm` has exactly one primary tag, and the classification in 3.1 is total over all four values of it. There is no word that is not a term and not a header.

**INV-TERM-2.** A word tagged `TAG_PRIMARY_BOXED` points at a word tagged `TAG_PRIMARY_HEADER`. Step 5 of 3.1 dereferences without checking on a release build and this invariant is what makes that safe.

**INV-TERM-3.** No tuple of arity zero exists on any process heap. Every empty tuple in the system is `ERTS_GLOBAL_LIT_EMPTY_TUPLE`, so an empty tuple built by any route compares identical to one built by any other, and copying one between processes allocates nothing.

**INV-TERM-4.** An integer whose value fits the range in 3.2 is always in the immediate form. The same value never exists as a bignum on one heap and a small on another, and never as a bignum at all. Arithmetic that produces a result in range normalises it back down. Equality on two integers is therefore a comparison of two words, and a reimplementation that leaves a small value in bignum form after an operation breaks `=:=` in a way that will not show up until something compares two numbers that arrived by different routes.

**INV-TERM-5.** A bitstring of at most `ERL_ONHEAP_BINARY_LIMIT` bytes is a heap bitstring, whatever produced it. This holds for slices of larger bitstrings as well as for freshly built ones, which is why a short slice does not keep a large binary alive.

**INV-TERM-6.** The word count reported by 3.6 is exactly the number of heap words a copy of the term consumes. This is what makes the figure useful for capacity planning rather than only for comparison.

### Ordering guarantees

**ORD-TERM-1.** The standard order over terms of different types is total and fixed: number, atom, reference, fun, port, pid, tuple, map, nil, list, bitstring. Every conforming implementation orders two terms of different types the same way, and this is language surface rather than an implementation detail, because programs sort mixed data and `ordered_set` tables are built on it.

**ORD-TERM-2.** Within a type the order is the one in 3.7 step 4, and it is also total and fixed for tuples, lists, maps, bitstrings, atoms and numbers.

The following are **not guaranteed** and a program that relies on any of them is relying on an accident.

An integer and a float of equal value are neither less nor greater. Sorting a list holding both leaves their relative position decided by whatever the sort does with equal elements, which for a stable sort is the input order and for an unstable one is nothing at all. A program that sorts `[1, 1.0]` and expects a particular one first is not reading a property of the terms.

The relative order of two distinct references, or of two pids, carries no meaning. It is stable within a running node, so an `ordered_set` keyed on references behaves, but the ordering does not survive a restart and says nothing about which was created first.

The order of two pids or ports from different nodes depends on node names and creation numbers rather than on anything the program controls, and comparing them across a network is not a way to break a tie deterministically.

Map iteration order is not the standard order of the keys, and is not specified here at all. It belongs to BP-MAP-001 and a program that reads it as sorted will be wrong on the large map representation.

### Yield points

There are none in this specification. Every algorithm in section 3 runs to completion without the process being preemptible partway through, including the construction of a tuple of `MAX_ARITYVAL` elements, which is a single uninterruptible copy of up to sixteen million words.

That is a deliberate statement rather than an omission. The steps marked `[alloc]` can trigger a garbage collection, and a collection is a long operation that runs inside the step, but the process does not become schedulable elsewhere partway through and no other process observes an intermediate state. A reimplementation that makes term construction yield has to say so, because code that builds a term and then inspects it is entitled to assume nothing ran in between.

## 5. Edge cases and error behaviour

**Arity zero tuples.** The rule in 3.4 step 1 is not about the word saved. The emulator contains an optimisation that reads the word after a tuple's arity word without first checking that the tuple has any elements, and the comment above the global literal's declaration says so. If a zero arity tuple were on a heap, that read would touch whatever follows it, which may be unallocated. Placing the single empty tuple in the literal area guarantees the word after it is a real allocated word, so the read is always safe and never has to be guarded. A reimplementation that has no such optimisation may put empty tuples on heaps, and it then has to accept that two empty tuples are not the same object, which is observable through the word count in 3.6 and nowhere else, since equality on tuples is structural.

**The small integer boundary.** Crossing `MAX_SMALL` changes nothing a program can observe except allocation. Arithmetic keeps working, results stay exact, and comparisons keep their meaning. What changes is that every value past the boundary costs words and every operation on one allocates. A reimplementation with a different `SMALL_BITS` is conforming in every respect except the word counts in section 6, and this is the single place where a 32 bit build differs from a 64 bit one in a way a program can see.

**Tuple arity above the limit.** `MAX_ARITYVAL` is 2^24 - 1 on both word sizes, because the arity shares the header word with the six subtag bits and the limit was set to a round number of bits rather than to whatever would fit. Asking for a larger tuple fails with `badarg` and not with `system_limit`, which is worth stating because it is the opposite of what the name of the condition suggests and a conformance test that expects `system_limit` will fail against ERTS.

The comment above the define is worth reading before choosing a limit for a reimplementation. The Erlang specification puts the maximum arity at 65535 and ERTS enforces 16777215 instead, so the enforced figure is two hundred and fifty six times the specified one. A reimplementation that enforces 65535 is within the specification and will reject tuples that ERTS accepts, which is a real incompatibility rather than a theoretical one for any code that builds a tuple from a list of unbounded length.

**Atom length.** An atom's name is limited to 255 characters and exceeding it raises `system_limit`. Characters and not bytes: `MAX_ATOM_CHARACTERS` is 255 and `MAX_ATOM_SZ_LIMIT` is four times that, so a 255 character atom of multibyte text is 510 bytes of name and is accepted, while a 256 character atom of plain ASCII is 256 bytes and is not. That limit belongs to BP-ATOM-001 and is stated here only because it is the one immediate whose payload has a size at all, so a reimplementation reading this section might otherwise assume atoms are unbounded.

**Bitstrings that are not whole bytes.** Everything in 3.5 is in bits and the byte count is derived. A bitstring of 7 bits has a byte size of 1 and a bit size of 7, and the heap cost is the same as for 8 bits, because the data is rounded up to whole words long before it is rounded up to whole bytes.

**Reading a header as a term.** Step 14 of 3.1. This is unreachable through any correct path and a reimplementation should treat reaching it as fatal rather than as an error to report, because there is no context at that point in which a sensible error could be constructed.

**The `0xF` subtag.** Free in the sense of having no definition and not free in the sense of being available. `_EXTERNAL_TAG_MASK` tests whether a term belongs to another node with a single mask over subtags `0xC` through `0xE`, and the header says in a comment that `0xF` is reserved to make that mask work. A reimplementation that wants a fifteenth boxed kind has to give up the single test or renumber the external three.

## 6. Observable surface

Everything below is reachable from Erlang without a special build.

| What | Call | Reports |
| --- | --- | --- |
| Word count including duplicates | `erts_debug:flat_size/1` | Exactly the algorithm in 3.6. Counts a shared subterm once per occurrence. |
| Word count accounting for sharing | `erts_debug:size/1` | The same walk with a seen set. Smaller than `flat_size` for any term with sharing in it, equal otherwise. |
| Word size | `erlang:system_info(wordsize)` | Bytes per word, so 8 or 4. Multiply by 8 for the `W` used in section 2.4. |
| Bytes for the wire | `erlang:external_size/1` | Nothing to do with heap words. Belongs to BP-DIST-001 and is listed here so it is not mistaken for one of the above. |
| Bitstring length | `byte_size/1` and `bit_size/1` | The rounded and the exact length. Neither reports the heap cost. |
| Standard order | the comparison operators, `lists:sort/1`, `ordered_set` tables | The order in ORD-TERM-1 and ORD-TERM-2. |
| Tuple arity | `tuple_size/1` | The arity from the header word. |

Two of those are the ones a conformance test should lean on.

`erts_debug:flat_size/1` makes every figure in section 2.4 checkable from Erlang with no instrumentation, on any build, which is why the word counts in this specification are stated as exact numbers rather than as approximations. A reimplementation that has a different `ERL_ONHEAP_BINARY_LIMIT`, a different `SMALL_BITS` or an empty tuple on the heap will disagree with this document through that one function and through nothing else.

The pair of `flat_size` and `size` is the only way from Erlang to see that sharing exists at all. On a term built as a tuple holding the same binary twice, `size` reports the tuple, one binary and the shared slot, and `flat_size` reports the tuple and two binaries. A reimplementation that copies eagerly and has no sharing will return the same number from both, which is conforming and detectable.

What is not observable is the tag encoding itself. No call returns the primary tag of a term, and nothing in section 2.1 through 2.3 can be checked from Erlang. Those tables are normative for a reimplementation that wants to share compiled BEAM code or a heap dump with ERTS, and a reimplementation that wants neither can choose its own encoding and satisfy every test in section 7.

## 7. Conformance

`CT-TERM-001` is not written. This section says what it will assert, so that the specification can be argued with before the tests exist.

**Word counts.** For each row of the shape table in section 2.4, build a term of that shape and check `erts_debug:flat_size/1` against the formula. The tuple and cons rows are checked across a range of sizes rather than at one point, because a formula that is right at n equals 3 and wrong at n equals 0 is the exact defect INV-TERM-3 exists to prevent.

**The bitstring threshold.** Scan sizes across the limit and assert the cost is 10 words at `ERL_ONHEAP_BINARY_LIMIT` bytes and 8 above it on a 64 bit build, and that it does not grow at all past the limit. Assert also that a slice of a large bitstring at or below the limit costs the heap bitstring figure and not the off heap one, which is INV-TERM-5 and is the part a reimplementation is most likely to get wrong because the eager copy looks like a pessimisation.

**The small boundary.** Find it by bisection rather than by asserting a constant, then check the found value against `MIN_SMALL` and `MAX_SMALL` computed from `erlang:system_info(wordsize)`. A test that hardcodes 2^59 passes on the wrong platform for the wrong reason.

**Small normalisation.** Produce a value in small range by an operation on two bignums and assert it costs zero words. This is INV-TERM-4 and the failure it catches is invisible to every other test.

**The empty tuple.** Build one by four routes, including one that crosses a process boundary, and assert all four cost zero words and compare identical. This is INV-TERM-3 and it is the only assertion in the suite that a reimplementation is permitted to fail, provided it declares that it does, because section 5 says the choice is open to an implementation without the read past the arity word.

**Standard order.** Sort a list holding one term of every type and assert the sequence in ORD-TERM-1. Assert separately that nil sorts above every tuple and every map and below any non empty list, because that is the position readers and reimplementers get wrong, and getting it wrong will not show up in a sort of terms that happen to be all the same type.

**What is not guaranteed.** Assert the negatives from section 4 as well. That an integer and a float of equal value are neither less nor greater is a one line test and it prevents a reimplementation from "fixing" the tie in a way that would break sorting stability elsewhere.

**Failure modes.** A tuple above `MAX_ARITYVAL` raises `badarg`. An atom name above 255 characters raises `system_limit`, and the test uses multibyte text so that a reimplementation counting bytes fails it. Both are asserted on the exact class, not on "it raised something".

## 8. Porting notes

**32 bit builds.** `SMALL_BITS` is 28 rather than the word size minus four spelled as `(64-4)`, which is the same rule written as a constant, and everything in section 2.4 that derives from it moves. A float becomes three words rather than two. `ERL_ONHEAP_BINARY_LIMIT` does not move, because it is a byte count, so the word cost of a 64 byte heap bitstring becomes 18 rather than 10 while the threshold stays where it was. `MAX_ARITYVAL` does not move either. A reimplementation that treats the whole of section 2.4 as scaling with the word size will get two of the eight rows wrong.

**Platforms with pointers narrower than the word.** The layout assumes an address fits in the word with the low bits free, which requires alignment rather than width, so a 64 bit word holding a 32 bit address is fine and wastes bits. What is not fine is the reverse.

**WebAssembly and other 32 bit address spaces with 64 bit arithmetic.** The tempting move is to keep 64 bit words for the integer range and use the top half for something. Step 2 of 3.3 forbids it: the shift is over the whole word and the arithmetic shift back relies on the sign bit being the word's sign bit. A port that wants both wide smalls and narrow pointers has to change 3.2 and 3.3 together and accept that the word counts in section 2.4 no longer follow from `SMALL_BITS` in the stated way.

**Implementations that do not share BEAM code with ERTS.** The three tables in section 2 are the encoding ERTS uses and not the only workable one. What a reimplementation cannot change and stay conforming is the set of kinds, the shapes and word counts in section 2.4 as far as they are observable through section 6, INV-TERM-1 through INV-TERM-6, and the order in section 4. The specific bit patterns matter only for reading an ERTS heap dump or loading ERTS compiled code, and a reimplementation doing neither should choose its own and say so.

**Implementations without a garbage collector of the same shape.** Step 10 of 3.5 links a `BinRef` into a per process list so that a reference count is released when the term dies. An implementation with tracing collection over the whole heap does not need the list and does need something else in its place, because the off heap data is not reachable by tracing the process heap alone.

## 9. Provenance

| What | Where |
| --- | --- |
| Primary tags | erts/emulator/beam/erl_term.h:70-75@OTP-29.0.5 |
| Immediate tags, four bits | erts/emulator/beam/erl_term.h:79-84@OTP-29.0.5 |
| Immediate tags, six bits | erts/emulator/beam/erl_term.h:86-90@OTP-29.0.5 |
| Header subtags and the group masks | erts/emulator/beam/erl_term.h:131-148@OTP-29.0.5 |
| `0xF` reserved for external terms | erts/emulator/beam/erl_term.h:149@OTP-29.0.5 |
| Header subtag values as assembled | erts/emulator/beam/erl_term.h:154-164@OTP-29.0.5 |
| `is_zero_sized`, the two ways a term costs nothing | erts/emulator/beam/erl_term.h:190@OTP-29.0.5 |
| `SMALL_BITS` on 64 bit | erts/emulator/beam/erl_term.h:263@OTP-29.0.5 |
| `SMALL_BITS` on 32 bit | erts/emulator/beam/erl_term.h:266@OTP-29.0.5 |
| `MAX_SMALL` and `MIN_SMALL` | erts/emulator/beam/erl_term.h:269-270@OTP-29.0.5 |
| `make_small`, the shift and the tag | erts/emulator/beam/erl_term.h:271@OTP-29.0.5 |
| `MAX_ARITYVAL`, and the comment on the specified limit | erts/emulator/beam/erl_term.h:318-322@OTP-29.0.5 |
| Why an arity zero tuple may not sit on a heap | erts/emulator/beam/erl_term.h:538-546@OTP-29.0.5 |
| The type numbers used by the comparison | erts/emulator/beam/erl_term.h:1441-1457@OTP-29.0.5 |
| The subtraction that reverses them | erts/emulator/beam/utils.c:2459@OTP-29.0.5 |
| The global empty tuple, declared | erts/emulator/beam/erl_global_literals.h:38@OTP-29.0.5 |
| `ErlSubBits`, five words | erts/emulator/beam/erl_bits.h:60-82@OTP-29.0.5 |
| `ERL_SUB_BITS_SIZE` | erts/emulator/beam/erl_bits.h:128@OTP-29.0.5 |
| `BinRef`, three words | erts/emulator/beam/erl_bits.h:135-139@OTP-29.0.5 |
| `ERL_BIN_REF_SIZE` | erts/emulator/beam/erl_bits.h:144@OTP-29.0.5 |
| `ERL_REFC_BITS_SIZE`, the eight word figure | erts/emulator/beam/erl_bits.h:147@OTP-29.0.5 |
| `ErlHeapBits`, two words of header | erts/emulator/beam/erl_bits.h:150-154@OTP-29.0.5 |
| `heap_bits_size`, the word count | erts/emulator/beam/erl_bits.h:155-161@OTP-29.0.5 |
| `ERL_ONHEAP_BINARY_LIMIT` | erts/emulator/beam/erl_bits.h:167@OTP-29.0.5 |
| Atom name limit of 255 characters | erts/emulator/beam/atom.h:29@OTP-29.0.5 |

The three tables in section 2 are generated from the first four rows of that list by `tools/bpc.py` and are not editable by hand. A change to any of those defines upstream, including a change to which subtags exist, fails the generator rather than silently rewriting the table, so a reader is never shown a table that agrees with a header nobody looked at.

This document is `draft` and the list of what stands between it and `reviewed` is short enough to write down. Six of its statements are not yet backed by a cell that CI runs, and each was checked by hand at the date below and nowhere else. They are the tuple arity limit and its failure class of `badarg`, the gap between the 65535 the Erlang specification names and the 16777215 ERTS enforces, the atom limit being 255 characters rather than bytes, the difference between `erts_debug:flat_size/1` and `erts_debug:size/1` on a term with sharing in it, INV-TERM-5 on small slices being copied out rather than held as references, and INV-TERM-4 on an in range result of bignum arithmetic normalising back to an immediate. The conformance suite in section 7 asserts all six, so writing it is what closes this out.

Verified on 2026-09-02 by tamnd against OTP-29.0.5, erts-17.0.5. Word counts measured on aarch64 macOS and on x86-64 Linux and identical on both. The 32 bit figures in section 2.4 and section 8 are read from the source and have not been measured, because no 32 bit build was available, and they are the weakest statements in this document.
