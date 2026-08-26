open Cmarkit

type kind = Annotate | Document
type cell = { prose: Block.t; code: Block.t }
type item = Row of cell | Rule
type container = { kind: kind; items: item list }
type Block.t += Container of container node

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

let add_code buf ~lang source =
  let lang = Option.value ~default:"plaintext" lang in
  Buffer.add_string buf {|<pre><code class="language-|};
  Buffer.add_string buf lang;
  Buffer.add_string buf {|">|};
  Cmarkit_html.buffer_add_html_escaped_string buf (strip_blank_lines source);
  Buffer.add_string buf "</code></pre>"

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

  let of_subline = of_line ~is_fence:(( = ) '\'')
end

let prepare content =
  let buf = Buffer.create (String.length content) in
  let emit line = Buffer.add_string buf line; Buffer.add_char buf '\n' in
  let flush lang lines =
    let lang = if String.equal lang "" then None else Some lang in
    add_code buf ~lang (String.concat "\n" (List.rev lines));
    Buffer.add_char buf '\n'
  in
  let rec go state lines =
    match (state, lines) with
    | `Sub (lang, lines), [] -> flush lang lines
    | _, [] -> ()
    | `Code (chr, count), line :: lines ->
        emit line;
        let state =
          match Fence.of_line ~is_fence:(( = ) chr) line with
          | Some (_, n, "") when n >= count -> `Text
          | _ -> state
        in
        go state lines
    | `Sub (lang, slines), line :: lines ->
        begin match Fence.of_subline line with
        | Some _ -> flush lang slines; go `Text lines
        | None -> go (`Sub (lang, line :: slines)) lines
        end
    | `Text, line :: lines -> begin
        let trimmed = String.trim line in
        if String.starts_with ~prefix:":::" trimmed then begin
          Buffer.add_char buf '\n';
          emit trimmed;
          Buffer.add_char buf '\n';
          go `Text lines
        end
        else
          match Fence.of_line line with
          | Some (chr, n, _) ->
              emit line;
              go (`Code (chr, n)) lines
          | None ->
              begin match Fence.of_subline line with
              | Some (_, _, info) -> go (`Sub (info, [])) lines
              | None -> emit line; go `Text lines
              end
      end
  in
  go `Text (String.split_on_char '\n' content);
  Buffer.contents buf

let marker = function
  | Block.Paragraph (p, _) ->
      let break_on_soft = false in
      let p = Block.Paragraph.inline p in
      let txts = Inline.to_plain_text ~break_on_soft p in
      begin match txts with
      | [ line ] ->
          let line = String.trim (String.concat "" line) in
          if String.starts_with ~prefix:":::" line then
            Some (String.trim (String.sub line 3 (String.length line - 3)))
          else None
      | _ -> None
      end
  | _ -> None

let opening block =
  match marker block with
  | Some "annotate" -> Some Annotate
  | Some "document" -> Some Document
  | Some _ | None -> None

let closing block = match marker block with Some "" -> true | _ -> false

let blocks = function
  | [] -> Block.empty
  | [ block ] -> block
  | blocks -> Block.Blocks (blocks, Meta.none)

let prose_of rev = blocks (List.rev rev)

let items_of_blocks kind bs =
  match kind with
  | Annotate ->
      let flush items = function
        | [] -> items
        | pending -> Row { prose= prose_of pending; code= Block.empty } :: items
      in
      let rec go items pending = function
        | [] -> List.rev (flush items pending)
        | Block.Blank_line _ :: rest -> go items pending rest
        | (Block.Code_block _ as code) :: rest ->
            go (Row { prose= prose_of pending; code } :: items) [] rest
        | Block.Thematic_break _ :: rest ->
            go (Rule :: flush items pending) [] rest
        | block :: rest -> go items (block :: pending) rest
      in
      go [] [] bs
  | Document ->
      let close items = function
        | None -> items
        | Some (code, pending) -> Row { prose= prose_of pending; code } :: items
      in
      let rec go items current = function
        | [] -> List.rev (close items current)
        | Block.Blank_line _ :: rest -> go items current rest
        | (Block.Code_block _ as code) :: rest ->
            go (close items current) (Some (code, [])) rest
        | Block.Thematic_break _ :: rest ->
            go (Rule :: close items current) None rest
        | block :: rest ->
            let current =
              match current with
              | Some (code, pending) -> Some (code, block :: pending)
              | None -> Some (Block.empty, [ block ])
            in
            go items current rest
      in
      go [] None bs

let rec group acc = function
  | [] -> List.rev acc
  | block :: rest ->
      begin match opening block with
      | None -> group (block :: acc) rest
      | Some kind ->
          begin match body [] rest with
          | None -> group (block :: acc) rest
          | Some (inner, rest) ->
              let items = items_of_blocks kind inner in
              group (Container ({ kind; items }, Meta.none) :: acc) rest
          end
      end

and body acc = function
  | [] -> None
  | block :: rest when closing block -> Some (List.rev acc, rest)
  | block :: rest -> body (block :: acc) rest

let parse content =
  let doc =
    Doc.of_string ~heading_auto_ids:true ~strict:false (prepare content)
  in
  let bs =
    match Block.normalize (Doc.block doc) with
    | Block.Blocks (bs, _) -> bs
    | block -> [ block ]
  in
  Doc.make ~defs:(Doc.defs doc) (Block.Blocks (group [] bs, Meta.none))

module Ctx = Cmarkit_renderer.Context

let code_block c node =
  let lang =
    Block.Code_block.info_string node
    |> Option.map fst
    |> Fun.flip Option.bind Block.Code_block.language_of_info_string
    |> Option.map fst
  in
  let source =
    Block.Code_block.code node
    |> List.map Block_line.to_string
    |> String.concat "\n"
  in
  add_code (Ctx.buffer c) ~lang source;
  Ctx.string c "\n"

let cell c cls block =
  Ctx.string c {|<div class="|};
  Ctx.string c cls;
  Ctx.string c {|">|};
  Ctx.block c block;
  Ctx.string c "</div>"

let item c kind = function
  | Rule -> Ctx.string c {|<hr class="rule">|}
  | Row { prose; code } ->
      Ctx.string c {|<div class="row">|};
      begin match kind with
      | Annotate -> cell c "note" prose; cell c "code" code
      | Document -> cell c "code" code; cell c "doc" prose
      end;
      Ctx.string c "</div>"

let container c { kind; items } =
  let cls = match kind with Annotate -> "annotate" | Document -> "document" in
  Ctx.string c {|<div class="|};
  Ctx.string c cls;
  Ctx.string c {|">|};
  List.iter (item c kind) items;
  Ctx.string c "</div>\n"

let renderer =
  let block c = function
    | Container (node, _) -> container c node; true
    | Block.Code_block (node, _) -> code_block c node; true
    | _ -> false
  in
  Cmarkit_renderer.compose
    (Cmarkit_html.renderer ~safe:false ())
    (Cmarkit_renderer.make ~block ())

let fold_headers doc =
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
  let block_ext_default folder acc = function
    | Container ({ items; _ }, _) ->
        let fold acc = function
          | Rule -> acc
          | Row { prose; code= _ } -> Folder.fold_block folder acc prose
        in
        List.fold_left fold acc items
    | _ -> acc
  in
  Folder.fold_doc (Folder.make ~block_ext_default ~block ()) [] doc |> List.rev

let to_html content =
  let doc = parse content in
  let headers = fold_headers doc in
  let top = List.fold_left (fun n (level, _) -> min n level) max_int headers in
  let sections =
    List.filter (fun (level, _) -> level = top) headers
    |> Yocaml.Markup.Toc.from_list
    |> Yocaml.Markup.Toc.to_html (fun title -> title)
  in
  (sections, Cmarkit_renderer.doc_to_string renderer doc)

let render = Yocaml.Task.lift to_html
