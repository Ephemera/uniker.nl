open Yocaml

module Make (S : sig
  val source : Path.t
  val target : Path.t
end) =
struct
  module Source = struct
    let summary = Path.(S.source / "summary.yml")
    let content = Path.(S.source / "content")
    let static = Path.(S.source / "static")
    let templates = Path.(S.source / "templates")
    let template file = Path.(templates / file)
    let cache = Path.(S.source / "_cache")
    let binary = Path.from_string Sys.argv.(0)
    let chapter name = Path.(content / name)
    let section name = Path.(content / name)
    let catalog_file name = Path.(content / (name ^ ".md"))
    let script = Path.(S.source / "js" / "catalog.js")
  end

  module Target = struct
    let dir = S.target

    let slug file =
      file
      |> Path.remove_extension
      |> Path.basename
      |> Option.value ~default:"index"

    let url file = "/" ^ slug file ^ "/"
    let page file = Path.(dir / slug file / "index.html")
    let index = Path.(dir / "index.html")
    let artifact_url ~section file = "/" ^ section ^ "/" ^ slug file ^ "/"

    let artifact_page ~section file =
      Path.(dir / section / slug file / "index.html")

    let catalog_url section = "/" ^ section ^ "/"
    let catalog_page section = Path.(dir / section / "index.html")
  end

  let starts_with prefix s =
    String.length s >= String.length prefix
    && String.equal (String.sub s 0 (String.length prefix)) prefix

  let site_nav ~url =
    let pkg = starts_with "/packages/" url in
    let uni = starts_with "/unikernels/" url in
    let book = (not pkg) && (not uni) && not (String.equal url "/") in
    Model.Site_nav.
      [
        entry ~label:"Tutorial" ~url:"/introduction/" ~current:book
      ; entry ~label:"Packages" ~url:"/packages/" ~current:pkg
      ; entry ~label:"Unikernels" ~url:"/unikernels/" ~current:uni
      ]

  let read_summary () =
    Yocaml_yaml.Eff.read_file_as_metadata
      (module Model.Toc)
      ~on:`Source Source.summary

  let read_title file =
    let open Eff in
    let+ page, _ =
      Yocaml_yaml.Eff.read_file_with_metadata
        (module Model.Page)
        ~on:`Source file
    in
    page#title

  let read_nav summary =
    let open Eff in
    List.traverse
      (fun part ->
        let+ entries =
          List.traverse
            (fun name ->
              let file = Source.chapter name in
              let+ title = read_title file in
              Model.Nav.entry ~title ~url:(Target.url file))
            part.Model.Toc.chapters
        in
        Model.Nav.part ~title:part.Model.Toc.title entries)
      (Model.Toc.parts summary)

  let read_artifacts section =
    let open Eff in
    let* files =
      read_directory ~on:`Source ~only:`Files ~where:(Path.has_extension "md")
        (Source.section section)
    in
    let+ pairs =
      List.traverse
        (fun file ->
          let+ meta, _ =
            Yocaml_yaml.Eff.read_file_with_metadata
              (module Model.Artifact)
              ~on:`Source file
          in
          (file, meta))
        files
    in
    Stdlib.List.sort (fun (_, a) (_, b) -> String.compare a#name b#name) pairs

  let artifact_items section pairs =
    Stdlib.List.map
      (fun (file, meta) ->
        Model.Catalog.Item.make ~name:meta#name
          ~url:(Target.artifact_url ~section file)
          ~version:meta#version ~kind:meta#kind ~description:meta#description
          ~tags:meta#tags)
      pairs

  let summary_nav ~title ~name ~url ~sections =
    Model.Nav.(
      mark_current ~url ~sections
        [ part ~ordered:false ~title [ entry ~title:name ~url ] ])

  let attach_shell ~url page =
    let open Eff in
    let+ summary = read_summary () in
    let page =
      page#with_book ~site_title:(Model.Toc.title summary)
        ~site_description:(Model.Toc.description summary)
    in
    page#with_site_nav (site_nav ~url)

  let with_context ~sections ~url page =
    let open Eff in
    let* summary = read_summary () in
    let+ nav = read_nav summary in
    let nav = Model.Nav.mark_current ~url ~sections nav in
    let prev, next = Model.Nav.neighbours ~url nav in
    let page =
      page#with_book ~site_title:(Model.Toc.title summary)
        ~site_description:(Model.Toc.description summary)
    in
    let page = page#with_site_nav (site_nav ~url) in
    (page#with_nav nav)#with_neighbours prev next

  let with_summary_context ~title ~name ~url ~sections page =
    let open Eff in
    let+ page = attach_shell ~url page in
    page#with_nav (summary_nav ~title ~name ~url ~sections)

  let process_static = Action.copy_directory ~into:Target.dir Source.static

  let process_script =
    Action.copy_file ~into:Path.(Target.dir / "static") Source.script

  let dependencies = [ Source.binary; Source.summary; Source.content ]
  let deps_for extra = dependencies @ extra

  let layout : type a.
         (module Yocaml.Required.DATA_INJECTABLE with type t = a)
      -> string
      -> (a * string, a * string) Task.t =
   fun (module M) template ->
    let open Task in
    Yocaml_jingoo.Pipeline.as_template (module M) (Source.template template)
    >>> Yocaml_jingoo.Pipeline.as_template
          (module M)
          (Source.template "layout.html")

  let process_page ~sections ~url ~into ~template file =
    let open Task in
    Action.write_static_file into
      begin
        Pipeline.track_files dependencies
        >>> Yocaml_yaml.Pipeline.read_file_with_metadata
              (module Model.Page)
              file
        >>> second Prose.render
        >>* (fun (page, (page_sections, content)) ->
        let open Eff in
        let sections = if sections then page_sections else None in
        let+ page = with_context ~sections ~url page in
        (page, content))
        >>> layout (module Model.Page) template
        >>> drop_first ()
      end

  let process_chapter file =
    process_page ~sections:true ~url:(Target.url file) ~into:(Target.page file)
      ~template:"chapter.html" file

  let process_chapters () =
    let open Eff in
    let* summary = read_summary () in
    let files =
      Model.Toc.parts summary
      |> Stdlib.List.concat_map (fun part -> part.Model.Toc.chapters)
      |> Stdlib.List.map Source.chapter
    in
    return (Action.batch_list files process_chapter)

  let process_index () =
    let open Task in
    Action.write_static_file Target.index
      begin
        Pipeline.track_files dependencies
        >>> Yocaml_yaml.Pipeline.read_file_with_metadata
              (module Model.Page)
              Path.(Source.content / "index.md")
        >>> second Prose.render
        >>* (fun (page, (_, content)) ->
        let open Eff in
        let+ page = attach_shell ~url:"/" page in
        (page, content))
        >>> layout (module Model.Page) "index.html"
        >>> drop_first ()
      end

  let process_artifact ~section ~title file =
    let open Task in
    let url = Target.artifact_url ~section file in
    Action.write_static_file
      (Target.artifact_page ~section file)
      begin
        Pipeline.track_files (deps_for [ Source.section section ])
        >>> Yocaml_yaml.Pipeline.read_file_with_metadata
              (module Model.Artifact)
              file
        >>> second Prose.render
        >>* (fun (page, (sections, content)) ->
        let open Eff in
        let+ page =
          with_summary_context ~title ~name:page#name ~url ~sections page
        in
        (page, content))
        >>> layout (module Model.Artifact) "artifact.html"
        >>> drop_first ()
      end

  let process_catalog ~section ~title ~items () =
    let open Task in
    let url = Target.catalog_url section in
    Action.write_static_file
      (Target.catalog_page section)
      begin
        Pipeline.track_files (deps_for [ Source.section section ])
        >>> Yocaml_yaml.Pipeline.read_file_with_metadata
              (module Model.Catalog)
              (Source.catalog_file section)
        >>> second Prose.render
        >>* (fun (page, (sections, content)) ->
        let open Eff in
        let+ page =
          with_summary_context ~title ~name:page#title ~url ~sections page
        in
        (page#with_items items, content))
        >>> layout (module Model.Catalog) "catalog.html"
        >>> drop_first ()
      end

  let process_section ~section ~title () =
    let open Eff in
    let+ pairs = read_artifacts section in
    let items = artifact_items section pairs in
    let each =
      Action.batch_list pairs (fun (file, _) ->
          process_artifact ~section ~title file)
    in
    let catalog = process_catalog ~section ~title ~items () in
    fun cache -> each cache >>= catalog

  let indexed = ref false

  let index_search cache =
    let open Eff in
    if !indexed then return cache
    else begin
      indexed := true;
      let+ (_ : string) =
        exec "npx"
          ~args:
            [
              "--yes"; "--loglevel=error"; "pagefind@latest"; "--site"
            ; Path.to_string Target.dir
            ]
      in
      cache
    end

  let process_all () =
    let open Eff in
    let* chapters = process_chapters () in
    let* packages = process_section ~section:"packages" ~title:"Packages" () in
    let* unikernels =
      process_section ~section:"unikernels" ~title:"Unikernels" ()
    in
    Action.restore_cache ~on:`Source Source.cache
    >>= process_static
    >>= process_script
    >>= chapters
    >>= packages
    >>= unikernels
    >>= process_index ()
    >>= Action.store_cache ~on:`Source Source.cache
    >>= index_search
end
