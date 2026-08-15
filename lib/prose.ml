type kind = Annotate | Document
type code = { lang: string option; source: string }
type row = { prose: string; code: code option }
type segment = Plain of string | Container of kind * row list

module Fence = struct
  let is_fence = function '`' | '~' -> true | _ -> false

  let of_line ?(is_fence = is_fence) line =
    let len = String.length line in
    let start = ref 0 in
    while !start < len && !start < 4 && line.[!start] = ' ' do
      incr start
    done;
    if !start >= len then None
    else
      let chr = line.[!start] in
      if Fun.negate is_fence chr then None
      else begin
        let stop = ref !start in
        while !stop < len && line.[!stop] = chr do
          incr stop
        done;
        let count = !stop - !start in
        if count < 3 then None
        else Some (chr, count, String.trim (String.sub line !stop (len - !stop)))
      end

  let close (chr, count) line =
    match of_line line with
    | Some (c, n, info) -> c = chr && n >= count && String.equal info ""
    | None -> false
end

module Container = struct
  let of_line line =
    let line = String.trim line in
    let len = String.length line in
    if len > 3 && String.sub line 0 3 = ":::" then
      match String.trim (String.sub line 3 (len - 3)) with
      | "annotate" -> Some Annotate
      | "document" -> Some Document
      | _ -> None
    else None

  let is_end line = String.equal (String.trim line) ":::"
end

let highlight_js_lang = function
  | "ocaml" | "ml" | "mli" -> "ocaml"
  | "sh" | "bash" | "zsh" | "shell" | "console" -> "bash"
  | "dune" -> "lisp"
  | "diff" | "patch" -> "diff"
  | ("json" | "yaml" | "xml" | "makefile" | "c" | "rust" | "python") as lang ->
      lang
  | _ -> "plaintext"

let escape_html str =
  let buf = Buffer.create (String.length str) in
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | chr -> Buffer.add_char buf chr)
    str;
  Buffer.contents buf

let wrap_code lang html =
  let lang = Option.fold ~none:"plaintext" ~some:highlight_js_lang lang in
  Fmt.str {|<pre><code class="language-%s">%s</code></pre>|} lang html

let strip_blank_lines source =
  let blank line = String.equal (String.trim line) "" in
  let rec drop = function
    | line :: rest when blank line -> drop rest
    | lines -> lines
  in
  String.split_on_char '\n' source
  |> drop
  |> List.rev
  |> drop
  |> List.rev
  |> String.concat "\n"

let code_to_html { lang; source } =
  wrap_code lang (escape_html (strip_blank_lines source))

let code_mapper =
  let block _mapper = function
    | Cmarkit.Block.Code_block (node, meta) ->
        let lang =
          Cmarkit.Block.Code_block.info_string node
          |> Option.map fst
          |> Fun.flip Option.bind
               Cmarkit.Block.Code_block.language_of_info_string
          |> Option.map fst
        in
        let source =
          Cmarkit.Block.Code_block.code node
          |> List.map Cmarkit.Block_line.to_string
          |> String.concat "\n"
        in
        let html = code_to_html { lang; source } in
        `Map
          (Some
             (Cmarkit.Block.Html_block
                (Cmarkit.Block_line.list_of_string html, meta)))
    | _ -> `Default
  in
  Cmarkit.Mapper.make ~block ()

let fold_headers doc =
  let open Cmarkit in
  let block _ acc = function
    | Block.Heading (heading, _) ->
        let level = Block.Heading.level heading in
        let inline = Block.Heading.inline heading in
        let text =
          inline
          |> Inline.to_plain_text ~break_on_soft:false
          |> List.map (String.concat "")
          |> String.concat "\n"
        in
        Folder.ret @@ ((level, (Inline.id inline, text)) :: acc)
    | _ -> Folder.default
  in
  Folder.fold_doc (Folder.make ~block ()) [] doc |> List.rev

let expand_subcode content =
  let buf = Buffer.create (String.length content) in
  let emit line = Buffer.add_string buf line; Buffer.add_char buf '\n' in
  let rec go state = function
    | [] -> ()
    | line :: rest ->
        begin match state with
        | `Code (chr, count) ->
            emit line;
            let state =
              let is_fence = ( = ) chr in
              match Fence.of_line ~is_fence line with
              | Some (_, n, "") when n >= count -> `Text
              | _ -> state
            in
            go state rest
        | `Sub ->
            let is_fence = ( = ) '\'' in
            begin match Fence.of_line ~is_fence line with
            | Some _ ->
                Buffer.add_string buf "```\n";
                go `Text rest
            | None -> emit line; go `Sub rest
            end
        | `Text ->
            begin match Fence.of_line line with
            | Some (chr, n, _) ->
                emit line;
                go (`Code (chr, n)) rest
            | None ->
                let is_fence = ( = ) '\'' in
                begin match Fence.of_line ~is_fence line with
                | Some (_, _, info) ->
                    Buffer.add_string buf "```";
                    Buffer.add_string buf info;
                    Buffer.add_char buf '\n';
                    go `Sub rest
                | None -> emit line; go `Text rest
                end
            end
        end
  in
  go `Text (String.split_on_char '\n' content);
  Buffer.contents buf

let parse ~defs content =
  Cmarkit.Doc.of_string ~defs ~heading_auto_ids:true ~strict:false
    (expand_subcode content)

let markdown_to_html ~defs content =
  let doc = parse ~defs content in
  let headers = fold_headers doc in
  let html =
    doc |> Cmarkit.Mapper.map_doc code_mapper |> Cmarkit_html.of_doc ~safe:false
  in
  (headers, html)

let text lines = String.concat "\n" (List.rev lines)

let joined lines =
  let content = text lines in
  if String.equal (String.trim content) "" then None else Some content

let items_of_lines lines =
  let push_prose acc pending =
    match joined pending with
    | None -> acc
    | Some content -> Either.Left content :: acc
  in
  let rec take_code fence acc = function
    | [] -> (text acc, [])
    | line :: rest when Fence.close fence line -> (text acc, rest)
    | line :: rest -> take_code fence (line :: acc) rest
  in
  let rec loop acc pending = function
    | [] -> List.rev (push_prose acc pending)
    | line :: rest ->
        begin match Fence.of_line line with
        | Some (chr, count, info) ->
            let lang =
              match String.split_on_char ' ' info with
              | "" :: _ | [] -> None
              | lang :: _ -> Some lang
            in
            let source, rest = take_code (chr, count) [] rest in
            loop
              (Either.Right { lang; source } :: push_prose acc pending)
              [] rest
        | None -> loop acc (line :: pending) rest
        end
  in
  loop [] [] lines

let rows_of_items kind items =
  let join a b = if String.equal a "" then b else a ^ "\n\n" ^ b in
  match kind with
  | Annotate ->
      let rec loop acc prose = function
        | [] ->
            List.rev
              (if String.equal prose "" then acc
               else { prose; code= None } :: acc)
        | Either.Left p :: rest -> loop acc (join prose p) rest
        | Either.Right code :: rest ->
            loop ({ prose; code= Some code } :: acc) "" rest
      in
      loop [] "" items
  | Document ->
      let rec loop acc = function
        | [] -> List.rev acc
        | Either.Left p :: rest -> (
            match acc with
            | row :: acc ->
                loop ({ row with prose= join row.prose p } :: acc) rest
            | [] -> loop [ { prose= p; code= None } ] rest)
        | Either.Right code :: rest ->
            loop ({ prose= ""; code= Some code } :: acc) rest
      in
      loop [] items

let segment source =
  let push_plain acc pending =
    match joined pending with
    | None -> acc
    | Some content -> Plain content :: acc
  in
  let rec take_container fence acc = function
    | [] -> None
    | line :: rest ->
        begin match fence with
        | Some f when Fence.close f line ->
            take_container None (line :: acc) rest
        | Some _ -> take_container fence (line :: acc) rest
        | None ->
            if Container.is_end line then Some (List.rev acc, rest)
            else
              let fence =
                match Fence.of_line line with
                | Some (chr, count, _) -> Some (chr, count)
                | None -> None
              in
              take_container fence (line :: acc) rest
        end
  in
  let rec go fence acc pending = function
    | [] -> List.rev (push_plain acc pending)
    | line :: rest ->
        begin match fence with
        | Some fence ->
            let fence = if Fence.close fence line then None else Some fence in
            go fence acc (line :: pending) rest
        | None ->
            begin match Fence.of_line line with
            | Some (chr, count, _) ->
                go (Some (chr, count)) acc (line :: pending) rest
            | None ->
                begin match Container.of_line line with
                | None -> go None acc (line :: pending) rest
                | Some kind ->
                    begin match take_container None [] rest with
                    | None -> go None acc (line :: pending) rest
                    | Some (inner, rest) ->
                        let rows = rows_of_items kind (items_of_lines inner) in
                        let acc =
                          Container (kind, rows) :: push_plain acc pending
                        in
                        go None acc [] rest
                    end
                end
            end
        end
  in
  go None [] [] (String.split_on_char '\n' source)

let cell cls html = {|<div class="|} ^ cls ^ {|">|} ^ html ^ "</div>"

let render_row ~defs kind { prose; code } =
  let headers, prose = markdown_to_html ~defs prose in
  let code = Option.fold ~none:"" ~some:code_to_html code in
  let cells =
    match kind with
    | Annotate -> cell "note" prose ^ cell "code" code
    | Document -> cell "code" code ^ cell "doc" prose
  in
  (headers, {|<div class="row">|} ^ cells ^ "</div>")

let render_segment ~defs = function
  | Plain content -> markdown_to_html ~defs content
  | Container (kind, rows) ->
      let cls =
        match kind with Annotate -> "annotate" | Document -> "document"
      in
      let headers, rows = List.split (List.map (render_row ~defs kind) rows) in
      let str =
        {|<div class="|} ^ cls ^ {|">|} ^ String.concat "" rows ^ "</div>"
      in
      (List.concat headers, str)

let collect_defs segments =
  let add defs content = Cmarkit.Doc.defs (parse ~defs content) in
  let of_segment defs = function
    | Plain content -> add defs content
    | Container (_, rows) ->
        List.fold_left (fun defs row -> add defs row.prose) defs rows
  in
  List.fold_left of_segment Cmarkit.Label.Map.empty segments

let to_html content =
  let segments = segment content in
  let defs = collect_defs segments in
  let headers, chunks = List.split (List.map (render_segment ~defs) segments) in
  let headers = List.concat headers in
  let top = List.fold_left (fun n (level, _) -> min n level) max_int headers in
  let sections =
    List.filter (fun (level, _) -> level = top) headers
    |> Yocaml.Markup.Toc.from_list
    |> Yocaml.Markup.Toc.to_html (fun title -> title)
  in
  (sections, String.concat "\n" chunks)

let render = Yocaml.Task.lift to_html
