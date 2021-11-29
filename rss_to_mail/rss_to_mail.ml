type mail = {
  sender : string;
  to_ : string option;
  subject : string;
  body_html : string;
  body_text : string;
  timestamp : int64;
}

type 'a state_key =
  | Next_update : int64 state_key
  | Previous_entries : SeenSet.t state_key
  | Page_contents : string state_key

module type FETCH = sig
  type error

  val fetch : Uri.t -> (string, error) result Lwt.t
end

module type STATE = sig
  type t
  type id

  val get : t -> id -> 'a state_key -> 'a option
  val set : t -> id -> 'a state_key -> 'a -> t
end

module Make (Fetch : FETCH) (State : STATE) = struct
  type feed = State.id * Feed_desc.t
  type update = { entries : int }

  type error =
    [ `Parsing_error of (int * int) * string
    | `Fetch_error of Fetch.error
    ]

  type log = State.id * [ `Updated of update | error | `Uptodate ]

  module Process_feed = struct
    (* Remove date for IDs that disapeared from the feed: 1 month *)
    let remove_date_from = Int64.add 2678400L

    let match_regexp regexp str =
      try
        ignore (Str.search_forward regexp str 0);
        true
      with Not_found -> false

    let match_regexp_opt regexp = function
      | Some str -> match_regexp regexp str
      | None -> false

    let match_regexp_content regexp = function
      | Some c -> match_regexp regexp c.Feed.content_text
      | None -> false

    let rec exec_filter entry = function
      | Feed_desc.And fs -> List.for_all (exec_filter entry) fs
      | Or fs -> List.exists (exec_filter entry) fs
      | Not f -> not (exec_filter entry f)
      | Match_title r -> match_regexp_opt r entry.Feed.title
      | Match_content r ->
          match_regexp_content r entry.summary
          || match_regexp_content r entry.content

    let process_content options entry =
      match options.Feed_desc.content with
      | `Keep -> entry
      | `Remove -> { entry with Feed.summary = None; content = None }

    let process ~now _feed_uri options seen_ids feed =
      let match_any_filter entry =
        match options.Feed_desc.filter with
        | Some f -> exec_filter entry f
        | None -> true
      in
      let new_ids, entries =
        Array.fold_right
          (fun entry (ids, news) ->
            match Feed.entry_id entry with
            | Some id when match_any_filter entry ->
                let entry = process_content options entry in
                let news =
                  if SeenSet.is_seen id seen_ids then news else entry :: news
                in
                (id :: ids, news)
            | Some _ | None -> (ids, news)
            (* Ignore entries without an ID *)
          )
          feed.Feed.entries ([], [])
      in
      let seen_ids = SeenSet.new_ids (remove_date_from now) new_ids seen_ids in
      (feed, seen_ids, entries)
  end

  let prepare_mail ~now ~subject ~sender feed options entries =
    let label, to_ = Feed_desc.(options.label, options.to_) in
    let body_html, body_text = Mail_body.gen_mail ~sender ?label feed entries in
    { sender; to_; subject; body_html; body_text; timestamp = now }

  let prepare_bundle ~now ~sender feed options entries =
    let prep subject = [ prepare_mail ~now ~subject ~sender feed options entries ] in
    match entries with
    | [] -> []
    | [ Feed.{ title = Some title; _ } ] -> prep title
    | _ ->
        prep (Format.sprintf "%d entries from %s" (List.length entries) sender)

  let prepare_mails ~now ~sender feed options entries =
    let prepare entry =
      let subject =
        match entry.Feed.title with
        | Some title -> title
        | None -> "New entry from " ^ sender
      in
      prepare_mail ~now ~subject ~sender feed options [ entry ]
    in
    let too_many_entries =
      match options.Feed_desc.max_entries with
      | Some m when List.length entries > m -> true
      | Some _ | None -> false
    in
    if too_many_entries
    then prepare_bundle ~now ~sender feed options entries
    else List.map prepare entries

  module Check_feed = struct
    let fetch uri =
      let resolve_uri = Uri.resolve "" uri in
      let parse_content contents =
        match Feed_parser.parse ~resolve_uri (`String (0, contents)) with
        | exception Feed_parser.Error (pos, err) ->
            Error (`Parsing_error (pos, err))
        | feed -> Ok feed
      in
      Fetch.fetch uri
      |> Lwt.map (function
           | Error e -> Error (`Fetch_error e)
           | Ok contents -> parse_content contents
           )
  end

  module Check_scraper = struct
    let fetch uri scraper =
      Fetch.fetch uri
      |> Lwt.map (function
           | Error e -> Error (`Fetch_error e)
           | Ok contents ->
               let resolve_uri = Uri.resolve "" uri in
               Ok (Scraper.scrap ~resolve_uri scraper contents)
           )
  end

  type nonrec mail = mail
  type nonrec 'a state_key = 'a state_key

  let sender_name feed_uri feed options =
    let ( ||| ) opt def =
      match opt with Some "" | None -> def () | Some v -> v
    in
    options.Feed_desc.title ||| fun () ->
    feed.Feed.feed_title ||| fun () ->
    Uri.host feed_uri ||| fun () -> Uri.to_string feed_uri

  let update_feed' ~now ~feed_id uri state options ~fetch ~prepare =
    let uri = Uri.of_string uri in
    let process ~first_update seen_ids = function
      | Error ((`Fetch_error _ | `Parsing_error _) as error) ->
          (* Set "next_update" even on error to avoid repeatedly calling them *)
          (Fun.id, error)
      | Ok feed ->
          let feed, seen_ids, entries =
            Process_feed.process ~now uri options seen_ids feed
          in
          let sender = sender_name uri feed options in
          let mails =
            (* Don't send anything on first update *)
            if first_update then [] else prepare ~now ~sender feed options entries
          in
          let seen_ids = SeenSet.filter_removed now seen_ids in
          let update_state state =
            State.set state feed_id Previous_entries seen_ids
          in
          (update_state, `Updated mails)
    in
    let first_update, seen_ids =
      match State.get state feed_id Previous_entries with
      | None -> (true, SeenSet.empty)
      | Some seen_ids -> (false, seen_ids)
    in
    fetch uri |> Lwt.map (process ~first_update seen_ids)

  (** Check a feed for updates. Returns the list of generated mails and updated
      feed datas. Log informations by calling [log] once for each feed. [now] is
      used for forgetting entries some time after they have been removed from
      the feed. *)
  let update_feed ~now state (feed_id, (feed, options)) =
    match feed with
    | Feed_desc.Feed url ->
        let fetch = Check_feed.fetch and prepare = prepare_mails in
        update_feed' ~now ~feed_id url state options ~fetch ~prepare
    | Scraper (url, scraper) ->
        let fetch uri = Check_scraper.fetch uri scraper
        and prepare = prepare_mails in
        update_feed' ~now ~feed_id url state options ~fetch ~prepare
    | Bundle (Feed url) ->
        let fetch = Check_feed.fetch and prepare = prepare_bundle in
        update_feed' ~now ~feed_id url state options ~fetch ~prepare
    | Bundle (Scraper (url, scraper)) ->
        let fetch = Fun.flip Check_scraper.fetch scraper
        and prepare = prepare_bundle in
        update_feed' ~now ~feed_id url state options ~fetch ~prepare

  let check_feed ~now state ((feed_id, (_, options)) as feed) =
    match State.get state feed_id Next_update with
    | Some next_update when next_update >= now ->
        Lwt.return (feed_id, Fun.id, `Uptodate)
    | _ ->
        update_feed ~now state feed
        |> Lwt.map (fun (updt, log) ->
               let updt state =
                 let state = updt state in
                 State.set state feed_id Next_update
                   (Utils.next_update now options)
               in
               (feed_id, updt, log)
           )

  let reduce_updated (acc_datas, acc_mails, logs) (url, update_data, log) =
    let acc_mails, log =
      match log with
      | `Updated mails ->
          (mails @ acc_mails, `Updated { entries = List.length mails })
      | (`Fetch_error _ | `Parsing_error _ | `Uptodate) as log ->
          (acc_mails, log)
    in
    (update_data acc_datas, acc_mails, (url, log) :: logs)

  (** Update a list of feeds in parallel *)
  let check_all ~now state feeds =
    Lwt_list.map_p (check_feed ~now state) feeds
    |> Lwt.map (fun results ->
           let state, mails, logs =
             List.fold_left reduce_updated (state, [], []) results
           in
           (state, mails, List.rev logs)
       )
end
