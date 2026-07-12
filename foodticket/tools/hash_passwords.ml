(* One-off migration: bcrypt-hash any plaintext passwords still in the
   users table.  Idempotent — rows already hashed ($2...) or empty are
   left untouched.  Run via scripts/hash-passwords.sh. *)

let getenv_or n d =
  match Sys.getenv_opt n with Some v when v <> "" -> v | _ -> d

let () =
  let db =
    Mysql.connect
      {
        Mysql.dbhost = Some (getenv_or "FT_DB_HOST" "127.0.0.1");
        Mysql.dbname = Some (getenv_or "FT_DB_NAME" "foodticket");
        Mysql.dbport = Some (int_of_string (getenv_or "FT_DB_PORT" "3306"));
        Mysql.dbuser = Some (getenv_or "FT_DB_USER" "foodticket");
        Mysql.dbpwd =
          Some
            (match Sys.getenv_opt "FT_DB_PASS" with
             | Some v when v <> "" -> v
             | _ -> failwith "FT_DB_PASS is required");
        Mysql.dbsocket = None;
      }
  in
  let res = Mysql.exec db "SELECT id, password FROM users" in
  let rec collect acc =
    match Mysql.fetch res with
    | None -> List.rev acc
    | Some [| Some id; Some pw |] -> collect ((id, pw) :: acc)
    | Some _ -> collect acc
  in
  let rows = collect [] in
  let migrated =
    List.fold_left
      (fun n (id, pw) ->
         if pw = "" || (String.length pw >= 2 && pw.[0] = '$' && pw.[1] = '2')
         then n
         else begin
           let h = Bcrypt.string_of_hash (Bcrypt.hash ~count:10 pw) in
           ignore
             (Mysql.exec db
                (Printf.sprintf "UPDATE users SET password='%s' WHERE id=%s"
                   (Mysql.escape h) id));
           n + 1
         end)
      0 rows
  in
  Mysql.disconnect db;
  Printf.printf "Hashed %d plaintext password(s) out of %d user rows.\n"
    migrated (List.length rows)
