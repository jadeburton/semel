import CLib

print("the answer is \(clib_answer()), twice \(clib_twice(clib_answer()))")
// Each of these links only with what the manifest's linkerSettings ask for, the C++
// runtime, and the target's assembly compiled (B-55).
print("label \(clib_label_length()), zlib \(clib_has_zlib()), scaled \(clib_scaled(7)), "
    + "assembled \(clib_asm_base() + clib_asm_offset())")
