(* Yoann Padioleau
 *
 * Copyright (C) 2022-2024 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)
open Common
open Fpath_.Operators
module Out = Semgrep_output_v1_t

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Parse a semgrep-validate command, execute it and return an exit code.
 *
 * This module performs rule validation by checking whether a rule is
 * correct by detecting different kinds of errors:
 *
 *  (1) YAML syntax errors (e.g., unclosed quote). We detect those
 *    errors thanks to our YAML parser and Yaml_to_generic.ml
 *
 *  (2) Semgrep rule schema errors (e.g., missing 'message:' field). We
 *    detect those thanks to Parse_rule.ml
 *    TODO: use the OCaml grace library of Cooper for better error messaging?
 *    or fallback to jsonschema in pysemgrep just for the error message like
 *    zz did?
 *
 *  (3) "Logical" errors, by running Semgrep rules (also called "meta" rules)
 *     on those target rules. We run Semgrep on Semgrep! We detect
 *     those thanks to the 'p/semgrep-rule-lints' ruleset.
 *     (hence the need for the network capability and Core_scan.caps below)
 *
 *  (4) TODO Other errors that can't be detected easily using Semgrep rules. We
 *    detect those thanks to Check_rule.ml.
 *
 * For more info see
 * https://semgrep.dev/docs/writing-rules/testing-rules#validating-rules
 *
 * Note that there was no 'pysemgrep validate' subcommand. Rule validation
 * was run with 'semgrep scan --validate ...' but it's better to have a separate
 * subcommand. Note that the legacy 'semgrep scan --validate' is redirected to
 * this file after having built a compatible Validate_CLI.conf.
 *
 * LATER: get rid of semgrep-core -check_rules and cleanup duplicated code
 * in Check_rule.ml.
 *)

(*****************************************************************************)
(* Types and constants *)
(*****************************************************************************)

(* Cap.stdout + Core_scan.caps + network (we run metachecking rules) *)
(* TODO: should use stdout, right now we abuse Logs.app
 * TODO? why Cap.tmp?
 *)
type caps = < Cap.stdout ; Cap.network ; Cap.tmp ; Cap.fork ; Cap.alarm >

(* The "meta" rules are stored in the semgrep-rules public repository here:
 * https://github.com/semgrep/semgrep-rules/tree/develop/yaml/semgrep
 *
 * The pack below is defined in the semgrep-rules-pack private repository here:
 * https://github.com/semgrep/semgrep-rule-packs/blob/master/semgrep-rule-lints.json
 *)
let metarules_pack = "p/semgrep-rule-lints"

(*****************************************************************************)
(* Pro hooks *)
(*****************************************************************************)

(* alt: could reuse the one in Test_subcommand.ml *)
let hook_pro_init : (unit -> unit) ref =
  ref (fun () ->
      failwith
        "semgrep validate --pro not available (need --install-semgrep-pro)")

(*****************************************************************************)
(* Run the conf *)
(*****************************************************************************)

(* TODO: split in 3 like in Test_subcommand.ml: targeting/validate/report *)
let run_conf (caps : caps) (conf : Validate_CLI.conf) : Exit_code.t =
  CLI_common.setup_logging ~force_color:true ~level:conf.common.logging_level;
  (* Metrics_.configure Metrics_.On; ?? and allow to disable it?
   * semgrep-rules/Makefile is running semgrep --validate with metrics=off
   * (and also --disable-version-check), but maybe because it is used from
   * 'semgrep scan'; in 'osemgrep validate' context, we should not even have
   * those options and we should disable metrics (and version-check) by default.
   *)
  Logs.debug (fun m -> m "conf = %s" (Validate_CLI.show_conf conf));
  if conf.pro then !hook_pro_init ();

  let settings = Semgrep_settings.load () in
  let token_opt = settings.api_token in
  (* Checking (1) and (2). Parsing the rules is already a form of validation.
   * Before running metachecks on those rules, we make sure we can parse them.
   * TODO: report not only Rule.invalid_rule_errors but all Rule.Error.t for (1)
   * in Config_resolver.errors.
   * TODO? need the network here since anyway we filter_map registry config
   * later. We currently abuse the ability for --config and rules_source
   * to specify a dir but since anyway we want to filter yaml files
   * that don't look like rules, probably better do our own file
   * targeting here, especially in osemgrep validate which does not need
   * to be backward compatible.
   * TODO: example of possible fatal_errors here?
   *)
  let rules_and_origin, fatal_errors =
    Rule_fetching.rules_from_rules_source ~token_opt ~rewrite_rule_ids:true
      ~strict:conf.core_runner_conf.strict
      (caps :> < Cap.network ; Cap.tmp >)
      conf.rules_source
  in
  let rules, invalid_rules =
    Rule_fetching.partition_rules_and_invalid rules_and_origin
  in
  invalid_rules
  |> List.iter (fun (err : Rule_error.invalid_rule) ->
         match err with
         (* to get the "Missing semgrep extension ... install --pro" error *)
         (* alt: just warn *)
         | MissingPlugin s, _, _ -> Error.abort s
         | _ -> ());
  (* Checking (3) *)
  let metacheck_errors =
    match conf.rules_source with
    | Rules_source.Pattern _ -> []
    | Rules_source.Configs _xs -> (
        (* In a validate context, rules are actually targets of metarules.
         * alt: could also process Configs to compute the targets.
         *)
        (* TODO(cooper): don't understand motivation of this filter_map. Not
         * sure why we wouldn't do this on non-local files (understand for
         * registry)
         *
         * Seems to be because we can't easily get the tmpfile and we are still
         * entirely file-oriented rather than being able to scan buffers.
         *)
        let targets =
          rules_and_origin
          |> List_.filter_map (fun (x : Rule_fetching.rules_and_origin) ->
                 match x.origin with
                 | Local_file path -> Some path
                 | CLI_argument
                 | Registry
                 | App
                 | Untrusted_remote _ ->
                     (* TODO: stricter: warn if we didn't validate since it
                      * wasn't in a local file already (e.g., registry or other
                      * remote URI)
                      *)
                     None)
        in
        let in_docker = !Semgrep_envvars.v.in_docker in
        let (config : Rules_config.t) =
          Rules_config.parse_config_string ~in_docker metarules_pack
        in
        (* There should not be any errors, because we got these rules online. *)
        let metarules_and_origin, _errors =
          Rule_fetching.rules_from_dashdash_config ~token_opt
            ~rewrite_rule_ids:true (* default *)
            (caps :> < Cap.network ; Cap.tmp >)
            config
        in
        let metarules, metaerrors =
          Rule_fetching.partition_rules_and_invalid metarules_and_origin
        in
        if metaerrors <> [] then
          Error.abort (spf "error in metachecks! please fix %s" metarules_pack);

        (* TODO? why using Core_runner instead of directly Core_scan? *)
        let core_run_func =
          Core_runner.mk_core_run_for_osemgrep
            (Core_scan.scan (caps :> Core_scan.caps))
        in
        let result_or_exn =
          core_run_func.run conf.core_runner_conf Find_targets.default_conf
            (metarules, []) targets
        in
        match result_or_exn with
        | Error exn -> Exception.reraise exn
        | Ok result ->
            let res = Core_runner.mk_result metarules result in
            (* TODO? sanity check errors below too? *)
            let Out.{ results; errors = _; _ } : Out.cli_output =
              Cli_json_output.cli_output_of_runner_result ~fixed_lines:false
                res.core res.hrules res.scanned
            in
            (* TOPORT?
                    ... run -check_rules in semgrep-core ...
                    parsed_errors += [
                      core_error_to_semgrep_error(e) for e in core_output.errors
                    ]
                    return dedup_errors(parsed_errors)
                 ...
                 def dedup_errors(errors: List[SemgrepCoreError]) -> List[SemgrepCoreError]:
                    return list({uniq_error_id(e): e for e in errors}.values())

               def uniq_error_id(
                   error: SemgrepCoreError,
               ) -> Tuple[int, Path, core.Position, core.Position, str]:
                   return (
                       error.code,
                       Path(error.core.location.path),
                       error.core.location.start,
                       error.core.location.end,
                       error.core.message,
                   )
            *)
            (* metarules match results are actually metacheck errors *)
            results)
  in

  (* TODO: checking (4) *)

  (* Summarizing findings (errors) *)
  let num_fatal_errors = List.length fatal_errors in
  let num_errors = List.length invalid_rules + List.length metacheck_errors in
  (* was logger.info, but works without --verbose, so Logs.app better *)
  Logs.app (fun m ->
      m
        "Configuration is %s - found %d fatal errors, %d skippable error(s), \
         and %d rule(s)."
        (if num_errors + num_fatal_errors =|= 0 then "valid" else "invalid")
        num_fatal_errors num_errors (List.length rules));
  (* coupling: with Check_rule.error and use of SemgrepMatchFound *)
  metacheck_errors
  |> List.iter (fun (x : Out.cli_match) ->
         Logs.err (fun m ->
             m "Semgrep match found at line %s:%d\n%s" !!(x.path) x.start.line
               x.extra.message));
  match num_errors with
  | 0 -> Exit_code.ok ~__LOC__
  | _else_ ->
      (* was a raise SemgrepError originally *)
      Error.abort "Please fix the above errors and try again."

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)
let main (caps : caps) (argv : string array) : Exit_code.t =
  let conf = Validate_CLI.parse_argv argv in
  run_conf caps conf