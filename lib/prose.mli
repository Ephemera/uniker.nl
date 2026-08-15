(** Rendering of a chapter: CommonMark, plus the two side-by-side containers the
    book uses to put a listing and its prose next to each other. *)

val render : (string, string option * string) Yocaml.Task.t
(** [render] turns the body of a chapter into [(sections, html)], where
    [sections] is the nested list of its headings, ready for the navigation, and
    [html] is the chapter itself. *)
