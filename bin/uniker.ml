let source = Yocaml.Path.rel []
let target = Yocaml.Path.rel [ "_site" ]

module Site = Uniker.Site.Make (struct
  let source = source
  let target = target
end)

let usage () =
  prerr_endline "usage: uniker build | uniker serve [port]";
  exit 1

let () =
  match Sys.argv with
  | [| _ |] | [| _; "build" |] -> Yocaml_unix.run ~level:`Info Site.process_all
  | [| _; "serve" |] ->
      Yocaml_unix.serve ~level:`Info ~target ~port:8888 Site.process_all
  | [| _; "serve"; port |] -> (
      match int_of_string_opt port with
      | Some port ->
          Yocaml_unix.serve ~level:`Info ~target ~port Site.process_all
      | None -> usage ())
  | _ -> usage ()
