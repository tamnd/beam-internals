# BP-DIST-001 The external term format

Status: reviewed
Applies to: OTP-29.0.5 (erts-17.0.5)
Lesson: m55
Depends on: BP-TERM-001
Conformance: CT-DIST-001

## 1. Scope

This specifies how a term is turned into a sequence of bytes and back: the tag that opens every encoding, the layout that follows each tag, which tag is chosen for a term that several tags could carry, the options that change the choice, and what a decoder is required to accept as against what an encoder is required to produce. It covers the format as `term_to_binary/1,2` and `binary_to_term/1,2` use it, which is the same format the distribution puts on a socket.

It does not specify the distribution protocol. The handshake, the flags two nodes agree on, the atom cache, fragmentation and the control message vocabulary are BP-DIST-002. The tags that belong to those mechanisms are listed in section 2.3 so that a decoder written from this document knows they exist and does not read one as a term, and they are not described further here. BP-DIST-002 is not written yet.

It does not specify heap representation. What a term looks like in memory, what it costs there, and the standard order over terms are BP-TERM-001. The dependency runs one way: this document names the term kinds and the order, and takes both as given.

The boundary that matters most is with BP-TERM-001, and it matters because the two disagree in a way a reader will not expect. The size of a term on the wire and its size on a heap are different numbers computed by different rules with different boundaries, and neither is a good predictor of the other. Section 2.5 states the two places they part company, because a reimplementation that derives one from the other will be wrong in both directions.

## 2. Data structures

### 2.1 The overall shape

An encoded term is the byte `131`, then one tag byte, then data whose layout the tag decides. The `131` appears once at the front of a term and not again in front of the terms nested inside it: a tuple of three atoms is one `131` followed by one tuple tag followed by three atom encodings with no version bytes of their own.

The `131` is `VERSION_MAGIC`. It has been 131 since before Erlang 4.2 and the comment above the define asks that it not be changed, on the grounds that changing it breaks other people's code. A reimplementation should read that as binding rather than as advice, because every library that speaks this format tests for the byte.

One value of the tag byte is not a term. Tag `80` says the four bytes after it are the size of the uncompressed encoding and everything after that is a zlib stream which inflates to the plain form without its version byte. A decoder has to handle it before it dispatches on anything else.

### 2.2 The tags

<!-- bpc: etf-tags -->
Read from `erts/doc/guides/erl_ext_dist.md` and checked against `erts/emulator/beam/external.h`. 32 tags. Widths are in bytes, `N` means a whole encoded term and `Len` or `Arity` means the field named earlier on the row.

| Value | Tag | What follows the tag byte | Status |
| --- | --- | --- | --- |
| 67 | `RECORD_EXT` | `#Fields` 4, `Flags` 1, `Module` N1, `Name` N2, `Field Names` N3, `Values` N4 | current |
| 70 | `NEW_FLOAT_EXT` | `IEEE float` 8 | current |
| 77 | `BIT_BINARY_EXT` | `Len` 4, `Bits` 1, `Data` Len | current |
| 82 | `ATOM_CACHE_REF` | `AtomCacheReferenceIndex` 1 | current |
| 88 | `NEW_PID_EXT` | `Node` N, `ID` 4, `Serial` 4, `Creation` 4 | current |
| 89 | `NEW_PORT_EXT` | `Node` N, `ID` 4, `Creation` 4 | current |
| 90 | `NEWER_REFERENCE_EXT` | `Len` 2, `Node` N, `Creation` 4, `ID ...` N' | current |
| 97 | `SMALL_INTEGER_EXT` | `Int` 1 | current |
| 98 | `INTEGER_EXT` | `Int` 4 | current |
| 99 | `FLOAT_EXT` | `Float string` 31 | current |
| 100 | `ATOM_EXT` | `Len` 2, `AtomName` Len | deprecated |
| 101 | `REFERENCE_EXT` | `Node` N, `ID` 4, `Creation` 1 | deprecated |
| 102 | `PORT_EXT` | `Node` N, `ID` 4, `Creation` 1 | current |
| 103 | `PID_EXT` | `Node` N, `ID` 4, `Serial` 4, `Creation` 1 | current |
| 104 | `SMALL_TUPLE_EXT` | `Arity` 1, `Elements` N | current |
| 105 | `LARGE_TUPLE_EXT` | `Arity` 4, `Elements` N | current |
| 106 | `NIL_EXT` | nothing follows | current |
| 107 | `STRING_EXT` | `Length` 2, `Characters` Len | current |
| 108 | `LIST_EXT` | `Length` 4, `Elements`, `Tail` | current |
| 109 | `BINARY_EXT` | `Len` 4, `Data` Len | current |
| 110 | `SMALL_BIG_EXT` | `n` 1, `Sign` 1, `d(0)` ... `d(n-1)` n | current |
| 111 | `LARGE_BIG_EXT` | `n` 4, `Sign` 1, `d(0)` ... `d(n-1)` n | current |
| 112 | `NEW_FUN_EXT` | `Size` 4, `Arity` 1, `Uniq` 16, `Index` 4, `NumFree` 4, `Module` N1, `OldIndex` N2, `OldUniq` N3, `Pid` N4, `Free Vars` N5 | current |
| 113 | `EXPORT_EXT` | `Module` N1, `Function` N2, `Arity` N3 | current |
| 114 | `NEW_REFERENCE_EXT` | `Len` 2, `Node` N, `Creation` 1, `ID ...` N' | current |
| 115 | `SMALL_ATOM_EXT` | `Len` 1, `AtomName` Len | deprecated |
| 116 | `MAP_EXT` | `Arity` 4, `Pairs` N | current |
| 117 | `FUN_EXT` | `NumFree` 4, `Pid` N1, `Module` N2, `Index` N3, `Uniq` N4, `Free vars ...` N5 | removed |
| 118 | `ATOM_UTF8_EXT` | `Len` 2, `AtomName` Len | current |
| 119 | `SMALL_ATOM_UTF8_EXT` | `Len` 1, `AtomName` Len | current |
| 120 | `V4_PORT_EXT` | `Node` N, `ID` 8, `Creation` 4 | current |
| 121 | `LOCAL_EXT` | the standard does not say | current |
<!-- bpc: end etf-tags -->

That table is generated from the standard in the OTP tree and then checked against the emulator's own tag defines, and a value that differs between the two stops the build rather than being resolved in favour of either. The two sources are independent in a way that matters: the document is what a third party implementation is written from and the header is what ERTS actually does, so a silent divergence between them is exactly the failure a specification exists to catch.

The `Status` column is the parenthetical the standard puts in the heading and nothing else. `PORT_EXT` carries no parenthetical and is still not emitted by a current node, which is a case of the document being less precise than section 2.4.

One thing the table shows only if it is read carefully. Every identifier tag carries a `Creation` field alongside the node name, and the creation is part of the identity and not a comment on it. Two pids whose node, ID and serial agree and whose creation differs are different pids, they compare unequal, and both report the same node from `node/1`. That is the mechanism that stops a message addressed to a process on a node that has since restarted from reaching a process on the new one that happens to have the same number. A decoder that drops the creation, or that normalises it, has built exactly the confusion the field exists to prevent.

Nothing in the decoding of an identifier checks that the node exists, has ever existed, or is reachable. Bytes naming a node this runtime has never spoken to decode into a perfectly ordinary pid that can be compared, stored in a map and sent to. This is not a gap: a node has to be able to hold identifiers for peers it has not contacted, because that is how a pid travels through a third node. A reimplementation that validates the node name at decode time has broken transitive routing.

### 2.3 Tags with no heading in the standard

<!-- bpc: etf-undocumented-tags -->
Defined in `erts/emulator/beam/external.h` with no heading of their own in the standard. 10 of them.

| Value | Name | What it is for |
| --- | --- | --- |
| 68 | `DIST_HEADER` | Opens a distribution message and carries the atom cache. The standard describes it under a heading that names the header rather than the tag. |
| 69 | `DIST_FRAG_HEADER` | Opens the first fragment of a message too large to send in one piece. |
| 70 | `DIST_FRAG_CONT` | Opens every fragment after the first. |
| 72 | `HOPEFUL_DATA` | Wraps an encoding that used a tag the far end may not understand, with a fallback beside it. |
| 73 | `ATOM_INTERNAL_REF2` | An atom by its index in this VM's atom table, two bytes. Valid inside one runtime instance only. |
| 74 | `BINARY_INTERNAL_REF` | A pointer to an existing off heap binary, so a term can move between processes without a copy. |
| 75 | `ATOM_INTERNAL_REF3` | An atom by its index in this VM's atom table, three bytes. Valid inside one runtime instance only. |
| 76 | `BITSTRING_INTERNAL_REF` | A pointer to an existing bitstring that is not a whole number of bytes, again without a copy. |
| 78 | `MAGIC_REF_INTERNAL_REF` | A pointer to a magic reference, which is a handle on a resource and has no wire form at all. |
| 80 | `COMPRESSED` | Says the next four bytes are the uncompressed size and the rest is zlib. The standard describes it in its opening section, with no heading of its own. |
<!-- bpc: end etf-undocumented-tags -->

Two things in that table are load bearing for a reimplementation.

`DIST_FRAG_CONT` is 70 and `NEW_FLOAT_EXT` is 70. They do not collide, because they are read at different places. A decoder tests the byte after `131` against the three distribution header tags only when it is at the start of a packet, and treats it as a term tag everywhere else. A decoder that dispatches on the byte alone, without knowing whether it stands at a packet boundary or a term boundary, will read the wrong one, and the input that exposes it is a float.

The five internal reference tags are not a wire format at all. They encode a pointer into this runtime instance and are used where a term is serialised without leaving the machine, which is what an ETS table and the `local` option do. A reimplementation may choose entirely different encodings for that job, because nothing outside the instance ever sees them, and a reimplementation that sends one over a socket has produced a term that means something else on the far side.

### 2.4 Encoding against decoding

The two sides of this format are not the same set of tags and a specification that states one set is wrong about the other.

An encoder in OTP 29 emits 25 of the 32 tags in section 2.2. Of the seven it never emits, five are narrow identifier forms that a current node has no reason to produce: `PID_EXT`, `PORT_EXT` and `REFERENCE_EXT` carry a one byte creation and were replaced when big creations became mandatory in OTP 23, `NEW_REFERENCE_EXT` was replaced at the same time, and `NEW_PORT_EXT` was replaced by `V4_PORT_EXT` in OTP 26. The sixth is `FUN_EXT`, which no release since R8 produces. The seventh is `ATOM_CACHE_REF`, which belongs to the distribution atom cache and not to this document.

A decoder in OTP 29 has a case for all 32 and accepts 31 of them. It accepts every narrow form an older node might send, and the case for `FUN_EXT` does nothing but fail, so that the removed tag produces an error rather than falling through into whatever the default arm does.

The rule a reimplementation needs is this. Be strict about what you emit and permissive about what you accept, and make the removed tag an explicit refusal rather than an unhandled case, because an unhandled case is a difference in behaviour between builds and an explicit refusal is a specification.

### 2.5 The two places the wire and the heap disagree

An integer that fits in `SMALL_BITS` costs nothing on a heap. The wire has its own idea of a small integer and it is a different number.

| Value | Heap words | Wire bytes | Wire tag |
| --- | --- | --- | --- |
| 255 | 0 | 3 | `SMALL_INTEGER_EXT` |
| 2^31 - 1 | 0 | 6 | `INTEGER_EXT` |
| 2^31 | 0 | 8 | `SMALL_BIG_EXT` |
| 2^59 - 1 | 0 | 12 | `SMALL_BIG_EXT` |
| 2^59 | 2 | 12 | `SMALL_BIG_EXT` |

The wire boundary is at 2^31 because `INTEGER_EXT` is a signed 32 bit field. The heap boundary is at 2^59 on a 64 bit build because four bits of the word are a tag. Between them lies a band of integers that are free in memory and arrive as bignums on a socket, and the largest integer that costs no heap words is twelve bytes to send.

The second disagreement runs the other way and is about shape rather than size.

| Term | Heap words | Wire bytes |
| --- | --- | --- |
| `[1, 2, 3]` | 6 | 7 |
| `{1, 2, 3}` | 4 | 9 |

The list is the cheaper of the two to send and the dearer of the two to hold. A cons cell is two words with no header, so a list pays per element in memory, while `STRING_EXT` encodes a list of bytes at one byte each and pays almost nothing on the wire. A tuple is the reverse. A reimplementation that reuses its heap size calculation to predict a wire size, or the other way round, will be wrong about lists in one direction and about integers in the other.

## 3. Algorithms

The dialect is in NOTATION.md. Byte counts are in bytes throughout, which is the one place a blueprint in this repository counts anything other than words, and it is because the thing being specified is a byte stream.

### 3.1 Encode a term

```
1. write `131`                                       [fail]
2. if the `local` option is set
3.     write `121` and reserve four bytes for a hash of this instance
4. encode T by 3.2 through 3.6, depth first          [yield] [fail]
5. if the `local` option is set
6.     write the hash of everything after the reserved bytes into them
7. if a compression level above zero was asked for
8.     compress by 3.7                               [yield]
9. return the bytes
```

Step 4 is one iterative walk over a work stack and not a recursion, which is what makes step 4 interruptible at all. A reimplementation that recurses will overflow a C stack on a deep list long before it becomes slow, and a term arriving from a socket is not required to be shallow.

Nothing in this algorithm reserves heap on the sending process except the result binary, so an encoder does not have the failure modes BP-TERM-001 section 3 is full of. What it does have is a size limit: a term whose encoding does not fit in the addressable result fails, and section 5 says with what.

### 3.2 Choose the tag for an integer

```
1. if V is in 0 through 255
2.     return `SMALL_INTEGER_EXT` with one byte
3. if V is in -2^31 through 2^31 - 1
4.     return `INTEGER_EXT` with four bytes, big endian, signed
5. let d be the bytes needed for the magnitude of V, least significant first
6. if d is at most 255
7.     return `SMALL_BIG_EXT` with a one byte count, a sign byte and d bytes
8. return `LARGE_BIG_EXT` with a four byte count, a sign byte and d bytes
```

Step 1 is unsigned and step 3 is signed, so -1 takes six bytes and 1 takes three. A reimplementation that treats step 1 as a signed byte range produces an encoding that decodes to the wrong number, since the receiving side reads `SMALL_INTEGER_EXT` as unsigned.

The bignum form is sign and magnitude, not two's complement. Zero has one representation, reached at step 1, and never reaches step 5.

### 3.3 Choose the tag for an atom

```
1. if the atom cache is in use and the atom is in it
2.     return `ATOM_CACHE_REF` with the cache index
3. let n be the length of the atom's name in bytes as UTF-8
4. if UTF-8 atoms are in use
5.     if n is at most 255
6.         return `SMALL_ATOM_UTF8_EXT` with a one byte length
7.     return `ATOM_UTF8_EXT` with a two byte length
8. if the name fits in latin1 and small atom tags are in use
9.     return `SMALL_ATOM_EXT` with the latin1 bytes
10. return `ATOM_EXT` with the latin1 bytes
```

Step 5 counts bytes. The limit on an atom name is 255 characters, which is a different quantity, and the two are only equal for names that are entirely ASCII. A 255 character atom of two byte characters is 510 bytes of name, is a legal atom, and takes `ATOM_UTF8_EXT` at step 7. A reimplementation that conflates the two limits will either reject legal atoms or emit a length field that does not fit.

Steps 8 through 10 are reachable only under `minor_version` 0 or 1. The default since OTP 26 is 2, which means step 4 is always taken. Both latin1 tags are deprecated and a reimplementation that never emits them is conforming, provided it decodes them, because a node running an older release may send them.

### 3.4 Choose the tag for a list

```
1. if L is the empty list
2.     return `NIL_EXT`
3. if every element of L is an integer in 0 through 255, L is a proper list,
       and L has at most 65535 elements
4.     return `STRING_EXT` with a two byte length and one byte per element
5. write `LIST_EXT` with a four byte element count
6. for each element
7.     encode the element                            [yield]
8. encode the tail, which is `NIL_EXT` for a proper list and any term otherwise
```

Step 3 is the whole reason a list of bytes is cheaper on the wire than the same bytes in a tuple, and it has three conditions rather than one. All three have to hold. A list of 65536 bytes fails the third and takes step 5, at which point it costs two bytes per element instead of one, so adding a single element to a list at the boundary adds 65540 bytes. An improper list of two bytes fails the second and takes step 5 as well, even though it is short and its elements are bytes.

Step 4 loses information that step 5 keeps. `STRING_EXT` says nothing about whether the elements were characters, so a decoder returns a list of integers and cannot return anything else. That is not a defect to be fixed in a reimplementation, it is the format, and a reimplementation that adds a string type to the wire has made a different format.

### 3.5 Encode a map

```
1. write `MAP_EXT` with a four byte pair count
2. if the `deterministic` option is set
3.     collect all pairs into an array
4.     sort the array by key in the standard order of BP-TERM-001  [yield]
5.     write each pair, key then value                             [yield]
6.     return
7. for each pair in the map's own iteration order
8.     write the key then the value                                [yield]
```

Step 7 is the default and its order is not term order and is not reproducible. For a small map it is the order of the keys in the flat representation, which is the order the keys were created in the atom table rather than anything about the map. For a large map it is a walk of the hash trie. Neither is a property a program may rely on, and section 4 says so as a boundary rather than as a guarantee.

Step 4 is a yield point and it is the only sort in this specification. The array can be as large as the map, so the sort runs in a resumable form and gives the scheduler its slice back partway through. A reimplementation that sorts with an ordinary library sort has made a map encoding that cannot be preempted, and a large enough map then holds a scheduler for as long as the sort takes.

### 3.6 Encode a bitstring

```
1. let b be the length of B in bits
2. if b is a multiple of 8
3.     return `BINARY_EXT` with a four byte byte count and the bytes
4. return `BIT_BINARY_EXT` with a four byte byte count, a byte holding the
       number of significant bits in the last byte, and the bytes
```

The bits in step 4 are counted from the most significant end of the last byte, and the field holds 1 through 8 rather than 0 through 7. A reimplementation that writes 0 for a whole final byte has produced something a conforming decoder will reject.

Nothing here depends on where the data lives in memory. A binary of 64 bytes and one of 4096 bytes differ by a factor of sixty four on the wire and cost the same on a heap, which is the third disagreement between the two sizes and the one that shows up in a capacity plan.

### 3.7 Compress

```
1. let plain be the encoding without its version byte, of length n
2. give zlib an output buffer of n - 5 bytes                       [yield]
3. if zlib did not fit the output in that buffer
4.     write `131` then plain, and return
5. write `131`, then `80`, then n as four bytes, then the compressed bytes
```

Step 2 is the algorithm's whole design and it is easy to read as an implementation detail. The buffer is deliberately five bytes smaller than the plain form, which is the size of the tag and the length field, so zlib fails exactly when compressing would not save anything. Step 4 then falls back with no marker of any kind. A caller who asked for compression and got the plain form cannot tell from the bytes that compression was attempted.

A reimplementation is free to make a different choice here, and if it does it has to say so, because the observable in section 6 is the size of the result and a decoder cannot tell the two designs apart.

### 3.8 Decode a term

```
 1. read `131` or fail                                             [fail]
 2. if the next byte is `80`
 3.     read the four byte size, inflate the rest, and continue on the result
 4. read the tag byte
 5. if the tag is not one this decoder accepts
 6.     fail badarg                                                [fail]
 7. if the tag names an atom and the `safe` option is set
 8.     look the name up, and fail if no such atom exists          [fail]
 9. read the fields the tag declares, or fail if they run out      [yield] [fail]
10. build the term on the process heap                             [alloc]
11. if the term has children, continue at step 4 for each          [yield]
12. if the `used` option is set
13.     return the term and the number of bytes read
14. return the term, and say nothing about any bytes left over
```

Step 14 is not a simplification of the algorithm, it is the algorithm. There is no check that the input held exactly one term, so extra bytes are read by nobody and reported to nobody. Step 9 is where too few bytes are caught, which is why a truncated encoding fails and an over long one does not.

Step 7 is the only security relevant step in this document and it is worth stating why. Without it, step 8 creates any atom the bytes name, atoms are never collected, and a sender who controls the bytes controls how much of a fixed table the receiver gives away. With it, a name that is not already an atom fails the decode.

The protection is narrower than it looks. `safe` refuses an atom that does not exist yet, so the same bytes that failed a moment ago succeed once anything else has created that atom by any route. It is a check on novelty and not on content, and section 5 says what else it does not cover.

Step 3 is the second security relevant step even though it does not look like one. The size field is attacker controlled and the inflated form can be very much larger than the bytes that arrived, so a decoder that allocates the declared size before checking anything has handed the sender an amplifier.

## 4. Invariants, ordering guarantees and yield points

### Invariants

**INV-DIST-1.** Every encoding begins with `131` and exactly one tag byte, and the version byte appears once per encoding and never in front of a nested term.

**INV-DIST-2.** Decoding an encoding of T produces a term equal to T under `=:=`, for every T that has a wire representation. Equality and not identity: pids, ports and references come back equal, and the copy is a distinct heap object. Funs and magic references are the exceptions and section 5 lists them.

**INV-DIST-3.** The tag chosen for a term is a function of the term's value and the options, and never of the term's heap representation. Two terms that are `=:=` encode identically under identical options, whatever route each of them took to exist. This is what makes an encoding usable as a hash key or an ETS key, and a reimplementation that lets a heap detail leak into the choice of tag breaks that without breaking any round trip test.

**INV-DIST-4.** An encoder emits the narrowest tag a value fits, for integers, atoms, tuples and lists. The narrow and wide forms of each are interchangeable to a decoder, so this is an invariant of the encoder alone, and a decoder may not assume it of bytes that arrive.

**INV-DIST-5.** A decoder accepts every tag any supported release emits, including the four narrow creation forms no current node produces. Compatibility runs backwards only: a decoder is not required to accept a tag from a future release, and `HOPEFUL_DATA` exists because the encoder cannot always know which release it is talking to.

### Ordering guarantees

**ORD-DIST-1.** With the `deterministic` option, map pairs are written in the standard order of the keys, which is the order in BP-TERM-001. Two encodings of the same map under that option, within one major release, are byte identical.

**ORD-DIST-2.** Everything other than map pair order is already determined by the term. Tuple elements, list elements, bignum digits and record fields have exactly one order in the encoding and it is the order they have in the term.

The following are **not guaranteed** and a program that relies on any of them is relying on an accident.

The default map pair order is not term order, is not the insertion order, and is not stable. For a small map it follows the order the key atoms were created in this runtime instance, so the same code encoding the same literal map produces different bytes on two nodes and can produce different bytes on the same node in two runs. For a large map it is a hash trie walk. Neither is specified and neither should be read.

`deterministic` is stable within a major release and not across one. An encoding stored under OTP 28 and compared byte for byte against a fresh encoding under OTP 29 may differ, and the documented option does not promise otherwise. A reimplementation that stores encodings as keys has to store the release alongside them.

The compressed form of a term is not stable. The zlib level is a hint, the fallback in 3.7 step 4 is silent, and two runs of the same encoder on the same term may produce different byte counts. Only the decoded term is stable.

The size of an encoding is not a function of the size of the term on a heap, in either direction. Section 2.5 gives the two cases where the ordering of two terms by one measure is the reverse of their ordering by the other.

### Yield points

There are four, and the presence of any is the difference between this specification and BP-TERM-001, which has none.

**Encoding a term**, 3.1 step 4 and the steps under it. The walk is given a budget of `ERTS_BIF_REDS_LEFT` times `TERM_TO_BINARY_LOOP_FACTOR`, which is 32, and returns the remainder as reductions on the way out. A term large enough to exhaust the budget suspends the calling process and resumes it with the work stack intact.

**Sorting a map for `deterministic`**, 3.5 step 4. A resumable sort, not the library one, because the array is as large as the map.

**Compressing**, 3.7 step 2. zlib is driven in chunks of `TERM_TO_BINARY_COMPRESS_CHUNK`, which is 2^18 bytes on a release build, and the process yields between chunks.

**Decoding**, 3.8 steps 9 and 11. The budget is bytes rather than terms: `B2T_BYTES_PER_REDUCTION` is 128, so a reduction buys 128 bytes of input, and a bulk copy is charged at `B2T_MEMCPY_FACTOR`, which is 8 bytes per reduction of the byte budget.

All four exist for the same reason. Both directions of this format are unbounded in the size of their input, and a scheduler that cannot take its thread back until an encode finishes is not a soft real time scheduler. A reimplementation that makes either direction uninterruptible has changed the scheduling properties of the whole system, not only of these two functions, and section 6 of BP-SCHED-001 says what that costs.

## 5. Edge cases and error behaviour

**A tag the decoder does not know.** `badarg`. Not a partial term, not a skipped field. There is no length prefix at the term level, so a decoder that does not understand a tag cannot step over it, and continuing is not an option a reimplementation has.

**The removed fun tag.** `FUN_EXT` has been unemitted since OTP R8 and undecodable since OTP 23, and the decoder has an explicit arm for it that fails rather than letting it reach the unknown tag path. The observable result is the same `badarg` either way. The reason to keep the explicit arm is that it documents the removal at the place a reader looks for it.

**Trailing bytes.** There is no framing check, and this is the statement in this document most likely to surprise a reader. `binary_to_term/1` reads one term, stops, and says nothing at all about the bytes it did not read. An encoding of `{a, b, c}` followed by eighteen bytes of anything returns `{a, b, c}` and no error. `binary_to_term/2` with `used` returns the term and the number of bytes consumed, and it is the only way a caller can find out that there was anything left over. A reimplementation that rejects trailing bytes in the one argument form has added a check ERTS does not perform, and a caller that reads a successful decode as proof that the whole input was one term is wrong on both implementations.

**Missing bytes are the other case.** An encoding cut short anywhere fails with `badarg`, because the decoder runs out of input rather than finishing early. Too few bytes is an error and too many is not, which is not symmetric and is worth stating in those words.

**`safe` and atoms.** The option refuses to create an atom and refuses to create an external function reference. It does not validate anything else. A decoded term can still be enormous, can still be deeply nested, and can still be a perfectly valid term that the receiving program has no business acting on. The documented warning says the option makes the data safe for the runtime and not for the application, and a reimplementation should copy that sentence rather than improve on it.

**`safe` is not a property of the bytes.** The same bytes are refused before the named atom exists and accepted after. Any route that creates the atom is enough, including a decode of the same bytes without `safe`. A test that asserts a fixed encoding is always refused will pass and then fail, in that order, in the same test run.

**Compression that does not help.** A term whose encoding zlib cannot shrink comes back as the plain encoding, with no compressed tag and nothing anywhere in the result to say that compression was asked for and declined. Five bytes of plain encoding stay five bytes. The only way to find out is to compare the length against the length without the option, and a caller that assumes the `80` tag is present because the option was passed will read the second byte as a tag and get a different term.

**Compression as an amplifier.** The four byte size field is chosen by the sender. Forty four bytes of input can declare and produce four thousand bytes of term, and the ratio has no bound the format imposes. A reimplementation that trusts the size field to allocate has built the vulnerability that field exists to describe.

**`local` and `deterministic` together.** Refused. The two options ask for opposite things, since `local` writes an instance specific hash and instance specific identifiers and `deterministic` promises the same bytes for the same term.

**What `local` actually changes.** It wraps the encoding in tag `121` and a four byte hash of the runtime instance, and inside that wrapper an identifier belonging to this instance carries `NIL_EXT` where its node name would otherwise go. That is why the encoding survives the node being named or renamed after the encode. It is not a compression option: for an identifier from another node the wrapper is pure overhead and the result is larger than the plain form.

**`minor_version` 0.** Floats become a 31 byte zero padded decimal text field and atoms become latin1. A float takes 33 bytes instead of 10 and the text is what `sprintf` with `%.20e` produces. A reimplementation supporting this version has to match that formatting exactly, because the far side reads it back with `sscanf` and any difference in the number of digits is a different number.

**Atom names at the limit.** 255 characters, and the class of the failure depends on which door the name came in through. `list_to_atom/1` on 256 characters raises `system_limit`, which is the class BP-TERM-001 states. Decoding an atom of 256 characters raises `badarg`, because the decoder reports a malformed encoding rather than an exhausted resource. Same limit, two classes, and a conformance suite that asserts one of them for both routes fails against ERTS.

The tag boundary is at 255 bytes and is a different boundary again, so an atom can be legal and still cross from the one byte length field to the two byte one. A 255 character name of two byte text is 510 bytes, is a legal atom, and takes the wide tag. Three limits, three different quantities, and none of them implies either of the others.

**Lists at the string boundary.** 65535 elements is the last length `STRING_EXT` can carry. The standard states this as a requirement on implementations rather than as an observation, so an encoder that emits a longer `STRING_EXT` is producing something no conforming decoder can read.

**Funs.** A fun encodes the MD5 of the significant parts of its module, an index, a uniq, the module name, the creating pid and the free variables. Decoding one on a node without that exact module loaded does not produce a working fun, and this is the one place where INV-DIST-2 does not hold. The failure is deferred to the call rather than raised at the decode, which makes it the hardest failure in this format to diagnose.

**Magic references.** No wire form. A resource handle cannot be sent to another node at all, and the internal tag in section 2.3 exists only so that one can be moved inside a single runtime instance.

## 6. Observable surface

Everything below is reachable from Erlang without a special build and without a second node.

| What | Call | Reports |
| --- | --- | --- |
| The bytes | `erlang:term_to_binary/1,2` | Exactly what the distribution would send, which is why none of this needs a cluster to study. |
| The term | `erlang:binary_to_term/1,2` | The inverse, with `safe` and `used` as the two options. |
| The size without the bytes | `erlang:external_size/1,2` | The byte count 3.1 would produce, computed without building the binary. |
| Bytes consumed | `binary_to_term/2` with `used` | Step 13 of 3.8. The only way to learn that the input held more than the term. |
| Whether compression helped | `byte_size/1` of the result | The only way to see the fallback in 3.7 step 4. There is no other signal. |
| Whether an atom already exists | `binary_to_term/2` with `safe` | Indirectly, and it is the mechanism in 3.8 step 7. |

Two of those carry more weight than the rest.

`external_size/1` makes every byte count in this document checkable from Erlang without allocating the encoding, so a conformance suite can assert sizes over a large corpus cheaply. It has to agree with `byte_size(term_to_binary(T))` for every T and every option set, and a reimplementation whose size estimate and encoder disagree has a bug that only shows up under memory pressure.

The pair of `external_size/1` and `erts_debug:flat_size/1` is the only way from Erlang to see that the two costs in section 2.5 are different quantities. A reimplementation that derives either from the other will pass every round trip test and fail the first size test written across the boundary.

What is not observable is the choice of tag, directly. Nothing returns "this term encoded as `STRING_EXT`". Every claim in section 3 about which tag was chosen has to be checked by reading the bytes, which is why the conformance suite in section 7 is written against byte patterns rather than against a decoded result.

## 7. Conformance

`CT-DIST-001`, in `conformance/suites/ct_dist_001.erl`, run by `conformance/run.escript`. 23 cases, every one of them Tier 0, which means one node with no name, no network and a stock release install. That is not a convenience, it is a property of the format worth stating in the conformance section: the bytes `term_to_binary/1` produces are the bytes the distribution sends, so the whole of this document can be checked without ever starting a second node.

| Case | Tier | What it asserts |
| --- | --- | --- |
| `round-trip` | 0 | INV-DIST-2 over a corpus of 34 terms covering every kind with a wire form, including an improper list, the empty containers, a bignum past the four byte length field, a bitstring that is not a whole number of bytes, and a map with keys of three types. |
| `round-trip-deterministic` | 0 | The same corpus under `deterministic`, and that encoding the same term twice gives the same bytes. |
| `external-size-agrees` | 0 | `external_size/1` and `byte_size(term_to_binary(T))` agree over the corpus, with and without options. A size estimator that disagrees with its own encoder fails only under memory pressure. |
| `tag-small-integer` | 0 | 255 takes the one byte tag and 256 does not, and -1 does not either, because that field is unsigned however small the value looks. |
| `tag-integer` | 0 | The signed 32 bit boundary in both directions, the 255 byte digit count boundary between the two bignum tags, and that a bignum and its negation are the same length, since the form is sign and magnitude. |
| `tag-atom` | 0 | 255 ASCII characters take the short tag, 128 two byte characters are 256 bytes and take the long one, and the longest legal atom is 255 characters and 510 bytes. |
| `tag-tuple` | 0 | 255 elements against 256, and the empty tuple. |
| `tag-string` | 0 | 65535 elements against 65536, and that the one extra element costs 65540 bytes. |
| `string-three-conditions` | 0 | Each of the three conditions in 3.4 step 3 broken on its own: an improper list, an element above 255, a negative element, a non integer element. A suite that varies only the length passes for the wrong reason. |
| `size-integer-band` | 0 | Section 2.5, the integer table. Fails rather than skips on a word size it has no numbers for. |
| `size-list-tuple-swap` | 0 | Section 2.5, the shape table, including the direction of both inequalities. |
| `deterministic-map-order` | 0 | With the option the pairs are in the standard order and three different insertion orders give one set of bytes. Without it the order is asserted only to differ from term order, never to be any particular thing. |
| `compression-declines` | 0 | A two byte binary asked to compress comes back as the plain encoding, byte for byte, with the tag it would have had anyway. |
| `compression-works` | 0 | Four thousand repeated bytes get the compressed tag, get smaller, round trip, and declare the right uncompressed size. |
| `safe-atom-order` | 0 | `safe` refuses, then plain accepts, then `safe` accepts the same bytes. The name is generated at run time so that nothing in the setup can have created the atom first. |
| `trailing-bytes-ignored` | 0 | There is no framing check. A term followed by junk decodes, `used` is the only way to learn the bytes were there, and a truncated encoding fails where an over long one does not. |
| `identifier-creation` | 0 | Two pids differing only in creation are unequal and report the same node. |
| `identifier-unknown-node` | 0 | An identifier for a node this runtime has never spoken to decodes, compares, works as a map key and round trips. |
| `bitstring-tags` | 0 | Which of the two tags a bitstring gets, that the bits field holds 1 through 8 rather than 0 through 7, and that the bits are counted from the top of the last byte. |
| `failure-classes` | 0 | Five failures on their exact class and reason, including the removed fun tag and `local` with `deterministic`. |
| `failure-atom-too-long` | 0 | The same limit through two doors, `badarg` on the decode and `system_limit` from `list_to_atom/1`. |
| `yield-encoding` | 0 | Encoding a 500000 element list charges more than one full scheduler slice, so the process was put down and picked up again. |
| `yield-decoding` | 0 | The same for decoding. |

What the suite does not cover is as much a decision as what it does, and it is recorded in `conformance/SCORECARD.md` rather than left for somebody to notice.

The four yield points in section 4 have two cases between them, both of which show that a reschedule happened and neither of which shows where. The reduction counter is the only instrument Tier 0 has, and it cannot tell an encode that trapped four times from one that trapped forty. Distinguishing them needs a trace, which is Tier 1, and the map sort and the compression chunk have no case at all.

The `minor_version` 0 float format is not exercised. It is a 31 byte zero padded decimal field read back with `sscanf`, and matching it needs a range of values compared against recorded output, which belongs with the corpora rather than here.

The fun failure in section 5 is not exercised, because reproducing it needs a second node without the module loaded, which is Tier 2.

The 32 bit column of section 2.5 has never been run. `size-integer-band` fails rather than skips on any word size other than 8, so the day somebody runs this on a 32 bit build they get a failure that says the numbers were never written down, which is the truth.

## 8. Porting notes

**32 bit builds.** Almost nothing in this document moves. The wire boundaries are byte counts and are the same on every word size. What moves is section 2.5, where the heap column changes and the wire column does not, so the band of integers that are free on the heap and expensive on the wire is narrower rather than absent. A reimplementation that reads section 2.5 as a property of the format has misread it: it is a property of the pair of formats.

**Endianness.** Every multibyte length and every integer field is big endian, and the bignum digits are the single exception, being least significant byte first. A reimplementation on a little endian machine that byte swaps uniformly will get the bignums wrong and nothing else, which is a defect that appears only above 2^31 and only for large values.

**Implementations without an atom table.** Steps 7 and 8 of 3.8 assume atoms are interned and that creating one is permanent. An implementation whose symbols are collected does not need `safe` for its own protection and still has to accept the option and behave as specified, because callers pass it and a reimplementation that ignores it has silently changed what a caller was promised.

**Implementations without preemption.** The four yield points in section 4 are the parts of this specification most easily left out and the ones whose absence is least visible in a test suite. An implementation with OS threads and no reduction counting does not need them in the same form and does need some answer to the same question, which is what stops one large term from occupying a worker for an unbounded time.

**Implementations that do not use zlib.** The compressed form is a zlib stream and the tag says nothing about the algorithm, so the choice is not open. A reimplementation using a different compressor has produced a format that only it can read, and should use its own tag outside this specification rather than reusing `80`.

**Reimplementing the encoder alone.** This is the common case, since a client library usually encodes and decodes and never joins a cluster. Such an implementation needs sections 2.2, 3.2 through 3.8, and INV-DIST-1 through INV-DIST-4. It does not need section 2.3 at all unless it speaks the distribution protocol, and reading section 2.3 as a list of tags to implement is the most likely way to waste a week.

## 9. Provenance

| What | Where |
| --- | --- |
| The overall shape, version byte and tag | erts/doc/guides/erl_ext_dist.md:24-46@OTP-29.0.5 |
| The compressed form | erts/doc/guides/erl_ext_dist.md:57-69@OTP-29.0.5 |
| The atom name limit of 255 characters | erts/doc/guides/erl_ext_dist.md:88-89@OTP-29.0.5 |
| The distribution header, which is out of scope here | erts/doc/guides/erl_ext_dist.md:91-107@OTP-29.0.5 |
| `SMALL_INTEGER_EXT` and `INTEGER_EXT` | erts/doc/guides/erl_ext_dist.md:351-365@OTP-29.0.5 |
| `STRING_EXT` and the 65535 requirement | erts/doc/guides/erl_ext_dist.md:503-513@OTP-29.0.5 |
| `LIST_EXT` and its tail field | erts/doc/guides/erl_ext_dist.md:515-524@OTP-29.0.5 |
| `SMALL_BIG_EXT`, sign and magnitude | erts/doc/guides/erl_ext_dist.md:535-550@OTP-29.0.5 |
| `BIT_BINARY_EXT`, bits counted from the top | erts/doc/guides/erl_ext_dist.md:675-685@OTP-29.0.5 |
| `ATOM_UTF8_EXT` and `SMALL_ATOM_UTF8_EXT` | erts/doc/guides/erl_ext_dist.md:697-724@OTP-29.0.5 |
| `LOCAL_EXT` and the instance hash | erts/doc/guides/erl_ext_dist.md:754-777@OTP-29.0.5 |
| `RECORD_EXT`, new in OTP 29 | erts/doc/guides/erl_ext_dist.md:778-803@OTP-29.0.5 |
| Every term tag define | erts/emulator/beam/external.h:33-63@OTP-29.0.5 |
| The distribution and internal tag defines | erts/emulator/beam/external.h:65-75@OTP-29.0.5 |
| `VERSION_MAGIC`, and the request not to change it | erts/emulator/beam/external.h:84-87@OTP-29.0.5 |
| `MAX_STRING_LEN` | erts/emulator/beam/external.c:60@OTP-29.0.5 |
| The three conditions on `STRING_EXT` | erts/emulator/beam/external.c:4238-4258@OTP-29.0.5 |
| Choosing an atom tag by byte count | erts/emulator/beam/external.c:2891-2905@OTP-29.0.5 |
| The internal atom reference tags | erts/emulator/beam/external.c:2869-2883@OTP-29.0.5 |
| The encoder's work stack states | erts/emulator/beam/external.c:3185-3194@OTP-29.0.5 |
| Sorting a map for `deterministic` | erts/emulator/beam/external.c:3418-3450@OTP-29.0.5 |
| The resumable sort, and why | erts/emulator/beam/external.c:3428-3446@OTP-29.0.5 |
| Choosing between the two bitstring tags | erts/emulator/beam/external.c:3846@OTP-29.0.5 |
| Compression, and the buffer five bytes short | erts/emulator/beam/external.c:2262-2282@OTP-29.0.5 |
| The compression chunk size | erts/emulator/beam/external.c:2326@OTP-29.0.5 |
| The encoder's reduction budget | erts/emulator/beam/external.c:2442@OTP-29.0.5 |
| The decoder's byte budget | erts/emulator/beam/external.c:1915-1916@OTP-29.0.5 |
| Reading the packet's first byte as a header tag | erts/emulator/beam/external.c:956-962@OTP-29.0.5 |
| `FUN_EXT` refused explicitly | erts/emulator/beam/external.c:6377-6382@OTP-29.0.5 |
| `TERM_TO_BINARY_LOOP_FACTOR` | erts/emulator/beam/dist.h:250@OTP-29.0.5 |
| The `compressed` option and its levels | erts/preloaded/src/erlang.erl:10012-10033@OTP-29.0.5 |
| `minor_version` and what each value changes | erts/preloaded/src/erlang.erl:10034-10052@OTP-29.0.5 |
| `deterministic`, and that it excludes `local` | erts/preloaded/src/erlang.erl:10057-10064@OTP-29.0.5 |
| `local`, and what it survives | erts/preloaded/src/erlang.erl:10065-10078@OTP-29.0.5 |
| `safe`, and what it does not cover | erts/preloaded/src/erlang.erl:1328-1346@OTP-29.0.5 |
| `used`, and its example with bytes left over | erts/preloaded/src/erlang.erl:1363-1377@OTP-29.0.5 |
| The atom name limit as a constant | erts/emulator/beam/atom.h:29-31@OTP-29.0.5 |

The two tables in section 2 are generated by `tools/bpc.py`. The first is read from the standard and cross checked against the emulator's defines, and a value that differs between them fails the build. The second is the set difference between the two sources, so a tag added upstream stops the build until somebody writes the sentence that explains it. Neither table is editable by hand.

This document is `reviewed`, and it is the first one here to leave `draft`, so the rule it was promoted under is written down rather than left to be inferred. A blueprint is `reviewed` when a conformance suite names it, the suite runs green on more than one architecture, and section 7 lists both what the suite covers and what it does not. `stable` is a stronger claim about the document holding across releases and nothing has earned it yet.

Two statements in this document were wrong when it was first written, and `CT-DIST-001` found both within an hour of existing. It said that `binary_to_term/1` rejects trailing bytes, which it does not, and it said that decoding an over long atom raises `system_limit`, which it does not either. Both were plausible, both were written from reading the source rather than running it, and neither would have been caught by any other check in this repository. They are recorded here rather than quietly corrected because the reason to build a conformance suite is that a specification nobody has run is a specification nobody has checked.

The claim in section 2.4 that a current encoder emits 25 tags and a decoder accepts 31 is still counted by reading the emulator rather than by exercising it, and is the one statement of substance here with no case behind it.

Verified on 2026-09-02 by tamnd against OTP-29.0.5, erts-17.0.5. Byte counts measured on aarch64 macOS and on x86-64 Linux and identical on both. The 32 bit column of section 2.5 is read from the source and has not been measured, because no 32 bit build was available.
