(* Authentication: bcrypt password hashing (safepass) and server-side
   session state (Eliom session scope).  Role checks happen here so no
   handler can forget them. *)

type user = { id : int; email : string; name : string; role : string }

let session_user : user option Eliom_reference.eref =
  Eliom_reference.eref ~scope:Eliom_common.default_session_scope None

let set_logged_in u = Eliom_reference.set session_user (Some u)

let logout () =
  Eliom_state.discard ~scope:Eliom_common.default_session_scope ()

let current_user () = Eliom_reference.get session_user

let hash_password p = Bcrypt.string_of_hash (Bcrypt.hash ~count:10 p)

let verify_password ~password ~hash =
  (* Legacy plaintext rows (empty or non-bcrypt) never verify. *)
  try Bcrypt.verify password (Bcrypt.hash_of_string hash) with _ -> false

(* Returns the session user if logged in with one of [roles], else None. *)
let require roles =
  let%lwt u = current_user () in
  match u with
  | Some u when List.mem u.role roles -> Lwt.return (Some u)
  | _ -> Lwt.return None
