open Brr

let words_of query =
  Jstr.cuts ~sep:(Jstr.v " ") (Jstr.lowercased query)
  |> List.filter (fun w -> not (Jstr.is_empty w))

(* NOTE(dinosaure): a really basic search engine. *)

let () =
  let doc = G.document in
  let filter = Document.find_el_by_id doc (Jstr.v "filter") in
  let cards = Document.find_el_by_id doc (Jstr.v "cards") in
  match (filter, cards) with
  | Some input, Some cards ->
      let empty = Document.find_el_by_id doc (Jstr.v "empty") in
      let data_search = Jstr.v "data-search" in
      let items =
        El.fold_find_by_selector ~root:cards
          (fun el acc -> el :: acc)
          (Jstr.v ".card") []
      in
      let apply () =
        let words = words_of (El.prop El.Prop.value input) in
        let fn shown card =
          let default = Jstr.empty in
          let str = Option.value ~default (El.at data_search card) in
          let fn w = Option.is_some (Jstr.find_sub ~sub:w str) in
          let matches = List.for_all fn words in
          El.set_prop El.Prop.hidden (not matches) card;
          if matches then shown + 1 else shown
        in
        let shown = List.fold_left fn 0 items in
        Option.iter (El.set_prop El.Prop.hidden (shown <> 0)) empty
      in
      ignore (Ev.listen Ev.input (fun _ -> apply ()) (El.as_target input));
      apply ()
  | _ -> ()
