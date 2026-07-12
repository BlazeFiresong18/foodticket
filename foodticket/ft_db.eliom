(* Database access helpers.  Connections are opened per operation and
   always released, including on exceptions. *)

let connect () =
  Mysql.connect
    {
      Mysql.dbhost = Some Ft_config.db_host;
      Mysql.dbname = Some Ft_config.db_name;
      Mysql.dbport = Some Ft_config.db_port;
      Mysql.dbuser = Some Ft_config.db_user;
      Mysql.dbpwd = Some Ft_config.db_pass;
      Mysql.dbsocket = None;
    }

let escape = Mysql.escape

let with_db f =
  let db = connect () in
  match f db with
  | v ->
    Mysql.disconnect db;
    v
  | exception e ->
    (try Mysql.disconnect db with _ -> ());
    raise e

let exec db sql = Mysql.exec db sql

let fetch_all res =
  let rec go acc =
    match Mysql.fetch res with
    | Some row -> go (row :: acc)
    | None -> List.rev acc
  in
  go []

(* Cell accessor: NULL becomes "" *)
let s = function Some x -> x | None -> ""
