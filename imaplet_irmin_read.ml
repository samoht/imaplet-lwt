(*
 * Copyright (c) 2013-2014 Gregory Tsipenyuk <gregtsip@cam.ac.uk>
 * 
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open Lwt
open Sexplib
open Irmin_storage
open Irmin_core
open Imaplet_types
open Utils
open Regex
open Dates
open Email_message
open Email_message.Mailbox

exception InvalidCmd
exception Quit

let uinput = ref []

let arg n =
  if List.length !uinput > n then
    List.nth !uinput n
  else
    raise InvalidCmd

let in_line () =
  Lwt_io.read_line Lwt_io.stdin

let out_line str =
  Lwt_io.write Lwt_io.stdout str >>= fun () ->
  Lwt_io.flush Lwt_io.stdout

let prompt str =
  out_line str >>= fun () ->
  in_line () >>= fun msg ->
  uinput := (Str.split (Str.regexp " ") msg);
  return (arg 0)

let rec tree key indent =
  IrminIntf.create () >>= fun store ->
  IrminIntf.list store key >>= fun l ->
  Lwt_list.iter_s (fun i -> 
    Printf.printf "%s%s%!" indent (Key_.key_to_string (Key_.t_of_list i));
    IrminIntf.mem store (Key_.t_of_list i) >>= fun res ->
    if res then (
      IrminIntf.read_exn store (Key_.t_of_list i) >>= fun v ->
      Printf.printf "%s\n%!" v;
      return ()
    ) else (
      Printf.printf "\n%!";
      tree (Key_.t_of_list i) (indent ^ "  ")
    )
  ) l

let message_template from_ to_ subject_ email_ =
let postmark = replace ~regx:"DATE" ~tmpl:(postmark_date_time()) "From FROM DATE" in
let postmark = replace ~regx:"FROM" ~tmpl:from_ postmark in
  let id_ = Pervasives.string_of_float (Unix.time()) in
  let message = 
  ("From: FROM\r\n" ^
  "Content-Type: text/plain; charset=us-ascii\r\n" ^
  "Content-Transfer-Encoding: 7bit\r\n" ^
  "Subject: SUBJECT\r\n" ^
  "Message-Id: <ID@localhost>\r\n" ^
  "Date: DATE\r\n" ^
  "To: TO\r\n" ^
  "\r\n" ^
  "EMAIL\r\n\r\n") in
  let message = replace ~regx:"FROM" ~tmpl:from_ message in
  let message = replace ~regx:"SUBJECT" ~tmpl:subject_ message in
  let message = replace ~regx:"TO" ~tmpl:to_ message in
  let message = replace ~regx:"EMAIL" ~tmpl:email_ message in
  let message = replace ~regx:"ID" ~tmpl:id_ message in
  let postmark = Mailbox.Postmark.of_string postmark in
  let email = Email.of_string message in
  {Message.postmark;email}

let append user mailbox =
  let open Storage_meta in
  prompt "from: " >>= fun from_ ->
  prompt "to: " >>= fun to_ ->
  prompt "subject: " >>= fun subject_ ->
  prompt "email: " >>= fun email_ ->
  let message = message_template from_ to_ subject_ email_ in
  IrminStorage.create user mailbox >>= fun str ->
  IrminStorage.append str message (empty_mailbox_message_metadata())

let rec selected user mailbox mbox =
  let open Storage_meta in
  let open Email_message in
  try
  prompt (user ^ ":" ^ mailbox ^ ": ") >>= function 
  | "help" -> Printf.printf
  "all\nexists\nhelp\nlist\nmeta\nappend\nmessage #\ntree
  \nclose\nremove uid\nstore # +-| flags-list\nquit\n%!";
  selected user mailbox mbox
  | "quit" -> raise Quit
  | "append" -> append user mailbox >>= fun () -> selected user mailbox mbox
  | "all" -> IrminMailbox.show_all mbox >>= fun () -> selected user mailbox mbox
  | "tree" -> let (_,key) = Key_.mailbox_of_path ~user mailbox in
    tree key "" >>= fun () -> selected user mailbox mbox
  | "exists" -> IrminMailbox.exists mbox >>= fun res ->
    (
     match res with
    | `No -> Printf.printf "no\n%!"
    | `Folder -> Printf.printf "folder\n%!"
    | `Mailbox -> Printf.printf "storage\n%!"
    ); selected user mailbox mbox
  | "meta" -> IrminMailbox.read_mailbox_metadata mbox >>= fun meta ->
    Printf.printf "%s\n%!" (Sexp.to_string (sexp_of_mailbox_metadata meta));
    selected user mailbox mbox
  | "message" -> let pos = arg 1 in
    (
    let pos = int_of_string pos in
    IrminMailbox.read_message mbox (`Sequence pos) >>= function
    | `Ok (message,meta) ->
      Printf.printf "%s\n%!" (Sexp.to_string (sexp_of_mailbox_message_metadata meta));
      Printf.printf "%s\n%!" (Mailbox.Message.to_string message);
      return ()
    | `NotFound -> Printf.printf "not found\n%!"; return ()
    | `Eof -> Printf.printf "eof\n%!"; return ()
    ) >>= fun() -> selected user mailbox mbox
  | "store" -> let pos = arg 1 in
  (
    let pos = int_of_string pos in
    IrminMailbox.read_message_metadata mbox (`Sequence pos) >>= function
    | `Ok (meta) ->
      let (_,flags) = List.fold_left 
      (fun (i,acc) el -> Printf.printf "%s\n%!" el;if i < 3 then (i+1,acc) else
          (i+1,(str_to_fl ("\\" ^ el)) :: acc)) (0,[]) !uinput in
      let find l i = try let _ = (List.find (fun el -> el = i) l) in true with _ -> false in
      let meta =
      (
      match (arg 2) with
      | "+" -> let flags = List.fold_left (fun acc i -> 
            if find acc i then acc else i :: acc) meta.flags flags in {meta with flags}
      | "-" -> let flags = List.fold_left (fun acc i ->
          if find flags i then acc else i :: acc) [] meta.flags in {meta with flags}
      | "|" -> {meta with flags}
      | _ -> raise InvalidCmd
      )
      in IrminMailbox.update_message_metadata mbox (`Sequence pos) meta >>= fun res ->
        ( match res with
        | `Ok -> Printf.printf "updated\n%!"
        | `Eof -> Printf.printf "eof\n%!"
        | `NotFound -> Printf.printf "not found\n%!"
        ); return ()
    | `NotFound -> Printf.printf "not found\n%!"; return ()
    | `Eof -> Printf.printf "eof\n%!"; return ()
  ) >>= fun () -> selected user mailbox mbox
  | "remove" -> let uid = arg 1 in IrminMailbox.delete_message mbox (`UID
  (int_of_string uid)) >>= fun () ->
      selected user mailbox mbox
  (*
  | "expunge" -> IrminMailbox.expunge mbox >>= fun deleted ->
      List.iter deleted ~f:(fun i -> Printf.printf "deleted %d\n%!" i);
      selected user mailbox mbox
  *)
  | "list" -> 
    IrminMailbox.list ~subscribed:false ~access:(fun _ -> true) mbox ~init:[] ~f:(
      fun acc item -> return ((item::acc))
    ) >>= fun l ->
    List.iter (fun i ->
      match i with
      | `Folder (f,i) -> Printf.printf "folder/%d %s\n%!" i f;
      | `Mailbox (m,i) -> Printf.printf "mailbox %s\n%!" m;
    ) l;
    selected user mailbox mbox
  | "close" -> return ()
  | _ -> Printf.printf "unknown command\n%!"; selected user mailbox mbox
  with InvalidCmd -> Printf.printf "unknown command\n%!"; selected user mailbox mbox

let main () =
  out_line "type help for commands\n" >>= fun () ->
  let rec request user =
    catch (fun () ->
    prompt (user ^ ": ") >>= function 
    | "help" -> Printf.printf "help\nselect mbox\ncrtmailbox mailbox\nlist\ntree\ndelete\ncreate\nuser\nquit\n%!"; request user
    | "user" -> prompt "user? " >>= fun user -> request user
    | "delete" -> let ac = UserAccount.create user in
      UserAccount.delete_account ac >> request user
    | "crtmailbox" -> let mailbox = arg 1 in
      IrminStorage.create user mailbox >>= fun str ->
      IrminStorage.create_mailbox str >>= fun () -> request user
    | "create" -> let ac = UserAccount.create user in
      UserAccount.create_account ac >> request user
    | "tree" -> 
      let key = Key_.create_account user in
      tree key "" >> request user
    | "select" -> 
      let mailbox = Str.replace_first (Str.regexp "+") " " (arg 1) in
      IrminMailbox.create user mailbox >>= fun mbox ->
      selected user mailbox mbox >>= fun () -> request user
    | "list" -> 
      IrminMailbox.create user "" >>= fun mbox ->
      IrminMailbox.list ~subscribed:false ~access:(fun _ -> true) mbox ~init:[] ~f:(
        fun acc item -> return ((item::acc))
      ) >>= fun l ->
      List.iter (fun i -> match i with
      | `Folder (i,c) -> Printf.printf "folder children:%d %s\n%!" c i
      | `Mailbox (i,c) -> Printf.printf "storage %d %s\n%!" c i) l; request user
    | "quit" -> return ()
    | _ -> Printf.printf "unknown command\n%!"; request user
    )
    (fun ex -> 
    match ex with
    | InvalidCmd -> Printf.printf "unknown command\n%!"; request user
    | Quit -> return ()
    | _ -> Printf.printf "exception %s\n%!" (Printexc.to_string ex); return ()
    )
  in
  prompt "user? " >>= fun user ->
  request user 

let () =
  Lwt_unix.run (main())
