(* Copy/Paste from our blog and examples from YOCaml *)

open Yocaml

module Link = struct
  type t = { title: string; url: string }

  let make ~title ~url = { title; url }

  let normalize { title; url } =
    Data.record [ ("title", Data.string title); ("url", Data.string url) ]
end

module Person = struct
  type t = { name: string; email: string; url: string option }

  let gravatar email =
    let key = String.lowercase_ascii (String.trim email) in
    let hash = Digest.to_hex (Digest.string key) in
    Format.asprintf "https://www.gravatar.com/avatar/%s?s=48&d=identicon" hash

  let validate =
    let open Data.Validation in
    record (fun fields ->
        let+ name = required fields "name" string
        and+ email = optional_or fields ~default:"" "email" string
        and+ url = optional fields "url" string in
        { name; email; url })

  let normalize { name; email; url } =
    Data.record
      [
        ("name", Data.string name); ("url", Data.option Data.string url)
      ; ("gravatar", Data.string (gravatar email))
      ]
end

module Site_nav = struct
  type entry = { label: string; url: string; current: bool }
  type t = entry list

  let entry ~label ~url ~current = { label; url; current }

  let normalize_entry { label; url; current } =
    Data.record
      [
        ("label", Data.string label); ("url", Data.string url)
      ; ("current", Data.bool current)
      ]

  let normalize entries = Data.list_of normalize_entry entries
end

module Nav = struct
  type entry = {
      title: string
    ; url: string
    ; current: bool
    ; sections: string option
  }

  type part = { title: string; ordered: bool; entries: entry list }
  type t = part list

  let entry ~title ~url = { title; url; current= false; sections= None }
  let part ?(ordered = true) ~title entries = { title; ordered; entries }

  let normalize_entry { title; url; current; sections } =
    Data.record
      [
        ("title", Data.string title); ("url", Data.string url)
      ; ("current", Data.bool current)
      ; ("sections", Data.option Data.string sections)
      ]

  let normalize_part { title; ordered; entries } =
    Data.record
      [
        ("title", Data.string title); ("ordered", Data.bool ordered)
      ; ("entries", Data.list_of normalize_entry entries)
      ]

  let normalize parts = Data.list_of normalize_part parts
  let flatten parts = List.concat_map (fun { entries; _ } -> entries) parts

  let neighbours ~url parts =
    let rec aux prev = function
      | [] -> (None, None)
      | entry :: rest when String.equal entry.url url ->
          let next =
            match rest with
            | [] -> None
            | e :: _ -> Some (Link.make ~title:e.title ~url:e.url)
          in
          (prev, next)
      | entry :: rest ->
          aux (Some (Link.make ~title:entry.title ~url:entry.url)) rest
    in
    aux None (flatten parts)

  let mark_current ~url ~sections parts =
    List.map
      (fun p ->
        {
          p with
          entries=
            List.map
              (fun e ->
                if String.equal e.url url then
                  { e with current= true; sections }
                else e)
              p.entries
        })
      parts
end

module Toc = struct
  let entity_name = "Toc"

  type part = { title: string; chapters: string list }
  type t = { title: string; description: string; parts: part list }

  let neutral =
    Data.Validation.fail_with ~given:"null" "Cannot be null"
    |> Result.map_error (fun error ->
        Required.Validation_error { entity= entity_name; error })

  let validate_part =
    let open Data.Validation in
    record (fun fields ->
        let+ title = required fields "title" string
        and+ chapters = required fields "chapters" (list_of string) in
        { title; chapters })

  let validate =
    let open Data.Validation in
    record (fun fields ->
        let+ title = required fields "title" string
        and+ description = optional_or fields ~default:"" "description" string
        and+ parts = required fields "parts" (list_of validate_part) in
        { title; description; parts })

  let title { title; _ } = title
  let description { description; _ } = description
  let parts { parts; _ } = parts
end

module Page = struct
  let entity_name = "Page"

  class type t = object ('self)
    method title : string
    method description : string
    method site_title : string
    method site_description : string
    method site_nav : Site_nav.t
    method nav : Nav.t
    method prev : Link.t option
    method next : Link.t option
    method with_book : site_title:string -> site_description:string -> 'self
    method with_site_nav : Site_nav.t -> 'self
    method with_nav : Nav.t -> 'self
    method with_neighbours : Link.t option -> Link.t option -> 'self
  end

  class page ~title ~description () =
    object (_ : #t)
      method title = title
      method description = description
      val site_title = ""
      val site_description = ""
      val site_nav = []
      val nav = []
      val prev = None
      val next = None
      method site_title = site_title
      method site_description = site_description
      method site_nav = site_nav
      method nav = nav
      method prev = prev
      method next = next

      method with_book ~site_title ~site_description =
        {<site_title; site_description>}

      method with_site_nav site_nav = {<site_nav>}
      method with_nav nav = {<nav>}
      method with_neighbours prev next = {<prev; next>}
    end

  let neutral =
    Data.Validation.fail_with ~given:"null" "Cannot be null"
    |> Result.map_error (fun error ->
        Required.Validation_error { entity= entity_name; error })

  let validate =
    let open Data.Validation in
    record (fun fields ->
        let+ title = required fields "title" string
        and+ description =
          optional_or fields ~default:"" "description" string
        in
        new page ~title ~description ())

  let normalize obj =
    [
      ("title", Data.string obj#title)
    ; ("description", Data.string obj#description)
    ; ("site_title", Data.string obj#site_title)
    ; ("site_description", Data.string obj#site_description)
    ; ("site_nav", Site_nav.normalize obj#site_nav)
    ; ("nav", Nav.normalize obj#nav)
    ; ("prev", Data.option Link.normalize obj#prev)
    ; ("next", Data.option Link.normalize obj#next)
    ]
end

module Artifact = struct
  let entity_name = "Artifact"

  class type t = object ('self)
    method name : string
    method version : string option
    method kind : string option
    method description : string
    method repo : string option
    method homepage : string option
    method tags : string list
    method authors : Person.t list
    method maintainers : Person.t list
    method site_title : string
    method site_description : string
    method site_nav : Site_nav.t
    method nav : Nav.t
    method with_book : site_title:string -> site_description:string -> 'self
    method with_site_nav : Site_nav.t -> 'self
    method with_nav : Nav.t -> 'self
  end

  class artifact ~name ~version ~kind ~description ~repo ~homepage ~tags
    ~authors ~maintainers () =
    object (_ : #t)
      method name = name
      method version = version
      method kind = kind
      method description = description
      method repo = repo
      method homepage = homepage
      method tags = tags
      method authors = authors
      method maintainers = maintainers
      val site_title = ""
      val site_description = ""
      val site_nav = []
      val nav = []
      method site_title = site_title
      method site_description = site_description
      method site_nav = site_nav
      method nav = nav

      method with_book ~site_title ~site_description =
        {<site_title; site_description>}

      method with_site_nav site_nav = {<site_nav>}
      method with_nav nav = {<nav>}
    end

  let neutral =
    Data.Validation.fail_with ~given:"null" "Cannot be null"
    |> Result.map_error (fun error ->
        Required.Validation_error { entity= entity_name; error })

  let validate =
    let open Data.Validation in
    record (fun fields ->
        let+ name = required fields "name" string
        and+ version = optional fields "version" string
        and+ kind = optional fields "kind" string
        and+ description = optional_or fields ~default:"" "description" string
        and+ repo = optional fields "repo" string
        and+ homepage = optional fields "homepage" string
        and+ tags = optional_or fields ~default:[] "tags" (list_of string)
        and+ authors =
          optional_or fields ~default:[] "authors" (list_of Person.validate)
        and+ maintainers =
          optional_or fields ~default:[] "maintainers" (list_of Person.validate)
        in
        new artifact
          ~name ~version ~kind ~description ~repo ~homepage ~tags ~authors
          ~maintainers ())

  let normalize obj =
    [
      ("name", Data.string obj#name); ("title", Data.string obj#name)
    ; ("version", Data.option Data.string obj#version)
    ; ("kind", Data.option Data.string obj#kind)
    ; ("description", Data.string obj#description)
    ; ("repo", Data.option Data.string obj#repo)
    ; ("homepage", Data.option Data.string obj#homepage)
    ; ("tags", Data.list_of Data.string obj#tags)
    ; ("authors", Data.list_of Person.normalize obj#authors)
    ; ("maintainers", Data.list_of Person.normalize obj#maintainers)
    ; ("site_title", Data.string obj#site_title)
    ; ("site_description", Data.string obj#site_description)
    ; ("site_nav", Site_nav.normalize obj#site_nav)
    ; ("nav", Nav.normalize obj#nav)
    ]
end

module Catalog = struct
  let entity_name = "Catalog"

  module Item = struct
    type t = {
        name: string
      ; url: string
      ; version: string option
      ; kind: string option
      ; description: string
      ; tags: string list
    }

    let make ~name ~url ~version ~kind ~description ~tags =
      { name; url; version; kind; description; tags }

    let search { name; kind; description; tags; _ } =
      String.lowercase_ascii
        (String.concat " "
           ((name :: description :: Option.to_list kind) @ tags))

    let normalize item =
      Data.record
        [
          ("name", Data.string item.name); ("url", Data.string item.url)
        ; ("version", Data.option Data.string item.version)
        ; ("kind", Data.option Data.string item.kind)
        ; ("description", Data.string item.description)
        ; ("tags", Data.list_of Data.string item.tags)
        ; ("search", Data.string (search item))
        ]
  end

  class type t = object ('self)
    method title : string
    method description : string
    method items : Item.t list
    method site_title : string
    method site_description : string
    method site_nav : Site_nav.t
    method nav : Nav.t
    method with_book : site_title:string -> site_description:string -> 'self
    method with_site_nav : Site_nav.t -> 'self
    method with_nav : Nav.t -> 'self
    method with_items : Item.t list -> 'self
  end

  class catalog ~title ~description () =
    object (_ : #t)
      method title = title
      method description = description
      val items = []
      val site_title = ""
      val site_description = ""
      val site_nav = []
      val nav = []
      method items = items
      method site_title = site_title
      method site_description = site_description
      method site_nav = site_nav
      method nav = nav

      method with_book ~site_title ~site_description =
        {<site_title; site_description>}

      method with_site_nav site_nav = {<site_nav>}
      method with_nav nav = {<nav>}
      method with_items items = {<items>}
    end

  let neutral =
    Data.Validation.fail_with ~given:"null" "Cannot be null"
    |> Result.map_error (fun error ->
        Required.Validation_error { entity= entity_name; error })

  let validate =
    let open Data.Validation in
    record (fun fields ->
        let+ title = required fields "title" string
        and+ description =
          optional_or fields ~default:"" "description" string
        in
        new catalog ~title ~description ())

  let normalize obj =
    [
      ("title", Data.string obj#title)
    ; ("description", Data.string obj#description)
    ; ("items", Data.list_of Item.normalize obj#items)
    ; ("site_title", Data.string obj#site_title)
    ; ("site_description", Data.string obj#site_description)
    ; ("site_nav", Site_nav.normalize obj#site_nav)
    ; ("nav", Nav.normalize obj#nav)
    ]
end
