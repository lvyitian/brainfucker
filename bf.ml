open Llvm

type program = command list
and command =
  | Incptr | Decptr
  | Incdata | Decdata
  | Output | Input
  | Loop of program

let read_program ic =
  let rec next cur stack =
    try
      match input_char ic, stack with
      | '>', _ -> next (Incptr :: cur) stack
      | '<', _ -> next (Decptr :: cur) stack
      | '+', _ -> next (Incdata :: cur) stack
      | '-', _ -> next (Decdata :: cur) stack
      | '.', _ -> next (Output :: cur) stack
      | ',', _ -> next (Input :: cur) stack
      | '[', _ -> next [] (cur :: stack)
      | ']', [] -> failwith "unmatched ']'"
      | ']', (hd :: tl) -> next (Loop (List.rev cur) :: hd) tl
      | _ -> next cur stack
    with End_of_file ->
      if List.length stack > 0 then failwith "unmatched '['";
      List.rev cur
  in
  next [] []

let compile memsize program =
  let ctx = global_context () in
  let m = create_module ctx "brainfucker" in

  let byte_ty = i8_type ctx in
  let byteptr_ty = pointer_type byte_ty in
  let bool_ty = i1_type ctx in
  let i32_ty = i32_type ctx in
  let void_ty = void_type ctx in

  let i w n = const_int (integer_type ctx w) n in
  let i8 = i 8 in
  let i32 = i 32 in

  let memset =
    let arg_types = [|byteptr_ty; byte_ty; i32_ty; i32_ty; bool_ty|] in
    declare_function "llvm.memset.p0i8.i32" (function_type void_ty arg_types) m
  in
  let putchar = declare_function "putchar" (function_type i32_ty [|byte_ty|]) m in
  let getchar = declare_function "getchar" (function_type byte_ty [||]) m in
  let cexit = declare_function "exit" (function_type void_ty [|i32_ty|]) m in

  (* use custom _start symbol rather than main function to reduce complexity *)
  let f = define_function "_start" (function_type void_ty [||]) m in
  let bb_cur = ref (entry_block f) in
  let b = builder_at_end ctx !bb_cur in

  let set_cur_bb bb =
    position_at_end bb b;
    bb_cur := bb
  in

  let mem = build_alloca (array_type byte_ty memsize) "mem" b in
  let ptr = build_alloca byteptr_ty "ptr" b in

  let load p = build_load p "" b in
  let store p value = ignore (build_store value p b) in
  let gep n = build_in_bounds_gep (load ptr) [|i32 n|] "" b in

  let rec compile_command = function
    | Incptr ->
      store ptr (gep 1)
    | Decptr ->
      store ptr (gep (-1))
    | Incdata ->
      build_add (load (gep 0)) (i8 1) "" b |> store (gep 0)
    | Decdata ->
      build_sub (load (gep 0)) (i8 1) "" b |> store (gep 0)
    | Output ->
      build_call putchar [|load (gep 0)|] "" b |> ignore
    | Input ->
      build_call getchar [||] "" b |> store (gep 0)
    | Loop p ->
      let bb_end = append_block ctx "" f in
      move_block_after !bb_cur bb_end;
      let bb_body = insert_block ctx "" bb_end in
      let bb_cond = insert_block ctx "" bb_body in

      build_br bb_cond b |> ignore;
      position_at_end bb_cond b;
      let cond = build_icmp Icmp.Eq (load (gep 0)) (i8 0) "" b in
      build_cond_br cond bb_end bb_body b |> ignore;

      set_cur_bb bb_body;
      List.iter compile_command p;
      build_br bb_cond b |> ignore;

      set_cur_bb bb_end
  in

  (* zero-initialize memory (use intrinsic for optimization assumptions) *)
  set_data_layout "e" m;  (* little-endian, needed for optimization *)
  let memptr = build_bitcast mem byteptr_ty "" b in
  build_call memset [|memptr; i8 0; i32 memsize; i32 0; i 1 0|] "" b |> ignore;

  (* set pivot to index 0 and compile program commands *)
  build_in_bounds_gep mem [|i32 0; i32 0|] "" b |> store ptr;
  List.iter compile_command program;

  (* exit gracefully *)
  build_call cexit [|i32 0|] "" b |> ignore;
  build_ret_void b |> ignore;
  m

let () =
  stdin |> read_program |> compile 30000 |> string_of_llmodule |> print_string
