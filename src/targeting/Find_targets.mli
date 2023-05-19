(*
   Find target files suitable to be analyzed by semgrep,
   regardless of rules or languages.
 *)

type conf = {
  (* global exclude list, passed via semgrep --exclude *)
  exclude : string list;
  (* global include list, passed via semgrep --include
   * Those are flags copied from grep (and ripgrep).
   *)
  include_ : string list option;
  max_target_bytes : int;
  (* whether or not follow what is specified in the .gitignore
   * TODO? what about .semgrepignore?
   *)
  respect_git_ignore : bool;
  (* TODO: not used for now *)
  baseline_commit : string option;
  (* TODO: not used for now *)
  scan_unknown_extensions : bool;
  (* osemgrep-only: option (see Git_project.ml and the force_root parameter) *)
  project_root : Fpath.t option;
}
[@@deriving show]

(* Entry point used by osemgrep.

   Take a set of scanning roots which are files or folders (directories) and
   expand them into the set of files that could be targets for some
   rules. Return a list of deduplicated paths to regular files.

   If a scanning root is a symbolic link, it is dereferenced recursively
   until it results in a regular file or a directory. However, we
   don't follow symbolic links discovered when listing directories.

   The order of the files isn't guaranteed to be anything special
   at the moment but we could obey some ordering if it makes sense to do it
   here.

   This may raise Unix.Unix_error if the scanning root does not exist.
*)
val get_targets :
  conf ->
  Fpath.t list (* scanning roots *) ->
  Fpath.t list * Output_from_core_t.skipped_target list

(* old implementation, more complete for ignoring paths, but returning
 * bad absolute fpaths instead of "readable" fpaths
 *)
val get_targets2 :
  conf ->
  Fpath.t list (* scanning roots *) ->
  Fpath.t list * Output_from_core_t.skipped_target list

(*
   [legacy implementation used in semgrep-core]

   Scan a list of folders or files recursively and return a list of files
   in the requested language. This takes care of ignoring undesirable
   files, which are returned in the semgrep-core response format.

   Reasons for skipping a file include currently:
   - the file looks like it's the wrong language.
   - a 'skip_list.txt' file was found at a conventional location (see
     skip_list.ml in pfff).
   - files over a certain size.
   See Skip_target.ml for more information.

   If keep_root_files is true (the default), regular files passed directly
   to this function are considered ok and bypass the other filters.

   By default files are sorted alphabetically. Setting
   'sort_by_decr_size' will sort them be decreasing size instead.

   This is a replacement for Lang.files_of_dirs_or_files.
*)
val files_of_dirs_or_files :
  ?keep_root_files:bool ->
  ?sort_by_decr_size:bool ->
  Lang.t option ->
  Fpath.t list ->
  Fpath.t list * Output_from_core_t.skipped_target list

(*
   Sort targets by decreasing size. This is meant for optimizing
   CPU usage when processing targets in parallel on a fixed number of cores.
*)
val sort_targets_by_decreasing_size :
  Input_to_core_t.target list -> Input_to_core_t.target list