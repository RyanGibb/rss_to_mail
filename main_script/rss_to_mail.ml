module Feed_options =
struct

	type t = {
		cache		: float; (** Cache timeout in hours *)
		label		: string option; (** Appended to the content *)
		no_content	: bool (** If the content should be removed *)
	}

	let of_obj obj =
		let prop name default map =
			let v = Js.Unsafe.get obj (Js.string name) in
			Js.Optdef.case v (fun () -> default) map
		in
		let some_string s = Some (Js.to_string s) in
		{	cache		= prop "cache"		6.		(fun v ->
				match Js.to_string v with
				| "always"		-> 0.2
				| "often"		-> 1.5
				| "sometimes"	-> 6.
				| "daily"		-> 24.
				| "rarely"		-> 72.
				| _				-> failwith "cache: Invalid value");
			label		= prop "label"		None	some_string;
			no_content	= prop "no_content"	false	Js.to_bool }

	let default () = of_obj (object%js end)

end

module Feed_spreadsheet =
struct

	type sheet_id = Js.js_string Js.t

	let read sheet_id =
		let ss = SpreadsheetApp.t##openById sheet_id in
		let sheet = Js.array_get ss##getSheets 0 in
		let sheet = Js.Optdef.get sheet (fun () -> failwith "Empty spreadsheet") in
		let last_row = sheet##getLastRow in
		let process_row row =
			let parse_options url options_data =
				try
					try Feed_options.of_obj (Js._JSON##parse options_data##toString)
					with Js.Error e -> failwith (Js.string_of_error e)
				with Failure e ->
					Console.error ("Malformed options: "
						^ Js.to_string url##toString ^ ": " ^ e);
					Feed_options.default ()
			in
			match Js.to_array row with
			| [| url; options_data |] ->
				(Js.to_string url##toString, parse_options url options_data)
			| _ -> assert false
		in
		if last_row <= 1
		then []
		else sheet##(getRange 2 1 (last_row - 1) 2)##getValues
			|> Js.to_array |> Array.map process_row |> Array.to_list

	let create () =
		let ss = SpreadsheetApp.t##create (Js.string "Rss to mail") 1 2 in
		let sheet = Js.array_get ss##getSheets 0 in
		let sheet = Js.Optdef.get sheet (fun () -> assert false) in
		sheet##appendRow (Js.array [| Js.string "Feed url"; Js.string "Options" |]);
		SpreadsheetApp.t##flush;
		ss##getId

end

(** `reqs` is an array of `(url, cache_timeout, process)`
	`cache_timeout` is in second
	`process` is a function that can process the result before it is cached *)
let cached_fetch_all clear_cache reqs =
	let cache = CacheService.t##getScriptCache in
	let cache_put url res cache_time =
		let cache_time = int_of_float cache_time in
		try
			cache##put url (Json.output res) cache_time
		with Js.Error e ->
			let msg = Js.to_string e##.message and url = Js.to_string url in
			Console.error ("Cache put failed: " ^ msg ^ ": " ^ url)
	in
	let reqs = Array.of_list reqs in
	let urls = Array.map (fun (url, _, _) -> Js.string url) reqs in
	let cached =
		if clear_cache
		then fun _ -> None
		else
			let cached = cache##getAll (Js.array urls) in
			fun index -> Js.Optdef.to_option (Js.Unsafe.get cached urls.(index))
	in
	let requests = new%js Js.array_empty in
	Array.iteri (fun index url ->
		if Option.is_none (cached index)
		then ignore (requests##push (object%js
				val url = url
				val muteHttpExceptions = Js._true
			end))) urls;
	let results = Js.to_array (UrlFetchApp.t##fetchAll requests) in
	let rec loop index req_index =
		if index >= Array.length reqs then []
		else match cached index with
			| Some cached	->
				(Json.unsafe_input cached) :: loop (index + 1) req_index
			| None			->
				let _, cache_time, process = reqs.(index) in
				let res =
					let res = results.(req_index) in
					if res##getResponseCode <> 200
					then process (`Error res##getResponseCode)
					else process (`Ok res##getContentText)
				in
				cache_put urls.(index) res cache_time;
				res :: loop (index + 1) (req_index + 1)
	in
	loop 0 0

let oldest_entry = Int64.of_int (7 * 24 * 3600000)

let load_spreadsheet () =
	let properties = PropertiesService.t##getUserProperties in
	let sheet_id_prop = Js.string "SHEET_ID" in
	Js.Opt.case (properties##getProperty sheet_id_prop)
		(fun () ->
			let sheet_id = Feed_spreadsheet.create () in
			properties##setProperty sheet_id_prop sheet_id;
			[])
		Feed_spreadsheet.read

let sort_entries entries =
	let cmp b a =
		match Feed.(a.date, b.date) with
		| Some a, Some b	-> Int64.compare a b
		| None, Some _		-> ~+1
		| Some _, None		-> ~-1
		| None, None		-> 0
	in
	let entries = Array.copy entries in
	Array.sort cmp entries;
	entries

let rec cut_entries i since entries =
	if i < Array.length entries
		&& (match entries.(i).Feed.date with
			| Some d	-> Int64.Infix.(>) d since
			| None		-> false)
	then cut_entries (i + 1) since entries
	else Array.sub entries 0 i

let opt_link title = function
	| Some link	-> "<a href=\"" ^ Uri.to_string link ^ "\">" ^ title ^ "</a>"
	| None		-> title

let img url styles =
	let styles = String.concat ";" styles in
	"<img style=\"" ^ styles ^ "\" src=\"" ^ Uri.to_string url ^ "\" />"

let update_entry feed_url feed options entry =
	let open Feed in
	let summary =
		let categories =
			let labels = List.map (function
				| { label = Some l; _ }	-> l
				| { term = Some t; _ }	-> t
				| _ -> "") entry.categories in
			match labels with
			| []		-> ""
			| l			-> " (" ^ String.concat ", " l ^ ")"
		and authors =
			let author a = opt_link a.author_name a.author_link in
			match List.map author entry.authors with
			| []		-> ""
			| authors	-> " by " ^ String.concat ", " authors
		and date =
			match entry.date with
			| Some d	-> "on " ^ Utils.date_string d
			| None		-> ""
		and summary =
			match entry.summary with
			| Some sum	-> "<p>" ^ sum ^ "</p>"
			| None		-> ""
		and feed_title =
			let icon = match feed.feed_icon with
				| Some url	-> img url [
					"display: inline !important";
					"height: 1em !important;";
					"margin: 0 0 -0.1em 0 !important;" ]
				| None		-> ""
			and title = match feed.feed_title with
				| Some title	-> title
				| None			-> feed_url
			in
			opt_link (icon ^ title) feed.feed_link
		and entry_title =
			let thumb = match entry.thumbnail with
				| Some url	-> img url [
					"display: block !important;";
					"max-width: 25em;" ]
				| None		-> ""
			in
			let p t = "<p>" ^ opt_link (t ^ thumb) entry.link ^ "</p>" in
			match entry.title, entry.link with
			| Some t, _		-> p t
			| None, Some l	-> p (Uri.to_string l)
			| None, None	-> ""
		and label =
			match options.Feed_options.label with
			| Some l	-> " with label " ^ l
			| None		-> ""
		and attachments =
			let attachment t =
				let info =
					match Option.(to_list (map Utils.size t.attach_size))
						@ Option.to_list t.attach_type with
					| []		-> ""
					| i			-> " (" ^ String.concat ", " i ^ ")"
				in
				let title =
					match String.Split.right ~by:"/" (Uri.path t.attach_url) with
					| Some (_, title) when String.contains title '.' -> title
					| _			-> Uri.to_string t.attach_url
				in
				let link = opt_link title (Some t.attach_url) in
				"<p>Attachment: " ^ link ^ info ^ "</p>"
			in
			String.concat "" (List.map attachment entry.attachments)
		in
		String.concat "" [
			"<p>Via "; feed_title; categories; "<br/>";
			date; authors; label; "</p>";
			entry_title;
			attachments;
			summary
		]
	in
	let content =
		match entry.content, options.Feed_options.no_content with
		| Some c, false	-> Some ((Js.string summary)##concat c)
		| _				-> Some (Js.string summary)
	and id = match entry.id, entry.link, entry.title with
		| Some id, _, _				-> Some (feed_url ^ id)
		| None, Some link, _		-> Some (feed_url ^ Uri.to_string link)
		| None, None, Some title	-> Some (feed_url ^ title)
		| None, None, None			-> None
	and title = match entry.title, entry.link with
		| Some _ as title, _	-> title
		| None, Some link		-> Some (Uri.to_string link)
		| None, None			-> Some feed_url
	in
	{ entry with id; title; summary = None; content }

let parse_feed contents =
	let open Xml_utils in
	try
		let root = parse contents in
		match tag root with
		| "rss"		-> Rss_format.parse root
		| "feed"	-> Atom_format.parse root
		| _			-> failwith "Unexpected format"
	with
	| Js.Error err				-> failwith (Js.to_string err##.message)
	| Child_not_found tag		-> failwith ("Missing tag " ^ tag)
	| Attribute_not_found attr	-> failwith ("Missing attribute " ^ attr)

class type params =
object
	method clear_cache_ : 'a. 'a Js.optdef Js.prop
end

let doGet (params : params Js.t) =
	let process_feed url options feed =
		sort_entries feed.Feed.entries
		|> cut_entries 0 (Int64.(sub (of_float Js.date##now) oldest_entry))
		|> Array.map (update_entry url feed options)
	in
	let process url options = function
		| `Ok contents	->
			begin try
				let feed = parse_feed contents in
				let feed = Feed.resolve_urls (Uri.of_string url) feed in
				let entries = process_feed url options feed in
				Console.info ("Fetched " ^ string_of_int (Array.length feed.entries)
					^ " entries (processed " ^ string_of_int (Array.length entries)
					^ ") from " ^ url);
				entries
			with Failure err ->
				Console.error ("Parsing error: " ^ err ^ ": " ^ url);
				[||]
			end
		| `Error code	->
			Console.error ("Fetch error: " ^ string_of_int code ^ ": " ^ url);
			[||]
	in
	Console.t##time (Js.string "all");
	let clear_cache = Js.Optdef.test params##.clear_cache_ in
	let entries =
		load_spreadsheet ()
		|> List.map (fun (url, options) ->
			let cache_time = options.Feed_options.cache *. 3600. in
			(url, cache_time, process url options))
		|> cached_fetch_all clear_cache
		|> Array.concat
		|> sort_entries
	in
	let output = Xml_utils.node @@ Atom_format.generate {
			feed_title = Some "Feed aggregator";
			feed_link = None;
			feed_icon = None;
			entries
		} in
	Console.t##timeEnd (Js.string "all");
	let output = XmlService.t##getPrettyFormat##format_element output in
	ContentService.t##(createTextOutput output)
		##setMimeType ContentService.MimeType._ATOM

let () = Js.export "rss_to_mail"
	(object%js
		method doGet params = doGet params##.parameter
	end)