
(** Test schema and generator
    @author Sylvain Le Gall
  *)

(* END EXPORT *)

open OASISTypes
open OASISSchema
open OASISValues
open OASISUtils
open OASISGettext

let schema, generator =
  let schm =
   schema "Test"
  in
  let cmn_section_gen =
    OASISSection.section_fields (s_ "test") schm
  in
  let build_tools = 
    OASISBuildSection.build_tools_field schm
  in
  let typ =
    new_field schm "Type"
      ~default:(OASISPlugin.builtin "none") 
      OASISPlugin.Test.value
      (fun () ->
         s_ "Plugin to use to run test.")
  in
  let command = 
    new_field_conditional schm "Command"
      command_line
      (fun () ->
         s_ "Command to run for the test.")
  in
  let working_directory =
    new_field schm "WorkingDirectory" 
      ~default:None
      (opt string_not_empty)
      (fun () ->
         s_ "Directory to run the test.")
  in
  let run = 
    new_field_conditional schm "Run"
      ~default:true
      boolean
      (fun () ->
         s_ "Enable this test.")
  in
    schm,
    (fun nm data ->
       Test
         (cmn_section_gen nm data,
          {
            test_type              = typ data;
            test_command           = command data;
            test_working_directory = working_directory data;
            test_run               = run data;
            test_build_tools       = build_tools data;
          }))