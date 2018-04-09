open Xml_utils
open Feed

let ns = namespace "http://www.w3.org/2005/Atom"

let parse feed_elem =
	let parse_entry entry =
		let date =
			Int64.of_float @@
			Js.date##parse (node (child ~ns "updated" entry))##getText
		and categories =
			let parse_category cat =
				let term = try Some (attribute "term" cat) with _ -> None in
				{ label = attribute "label" cat; term }
			in
			children ~ns "category" entry |> List.map parse_category
		in
		{	id = text (child ~ns "id" entry);
			title = text (child ~ns "title" entry);
			content = text (child ~ns "content" entry);
			author = text (child ~ns "name" (child ~ns "author" entry));
			link = attribute "href" (child ~ns "link" entry);
			date; categories }
	in
	let feed_title = text (child ~ns "title" feed_elem)
	and feed_link =
		try
			let alternate link =
				try attribute "rel" link = "alternate"
				with _ -> false in
			List.find alternate (children ~ns "link" feed_elem)
			|> fun link -> Some (attribute "href" link)
		with _ -> None
	and entries = List.map parse_entry (children ~ns "entry" feed_elem) in
	{ feed_title; feed_link; entries }

let generate feed =
	let gen_entry entry =
		let gen_category cat =
			let term = match cat.term with
				| Some t	-> [ "term", t ]
				| None		-> []
			in
			create ~ns "category" ~attr:(("label", cat.label) :: term) []
		in
		create ~ns "entry" (
			create ~ns "author" [ create_text ~ns "name" entry.author ]
			:: create_text ~ns "title" entry.title
			:: create_text ~ns "content" ~attr:[ "type", "html" ] entry.content
			:: create_text ~ns "id" entry.id
			:: create ~ns "link" ~attr:[ "href", entry.link ] []
			:: create_text ~ns "updated" (entry_date_string entry)
			:: List.map gen_category entry.categories)
	in
	let link = match feed.feed_link with
		| Some link	-> [ create ~ns "link" ~attr:[ "href", link ] [] ]
		| None		-> []
	in
	create ~ns "feed" (
		[ create_text ~ns "title" feed.feed_title ] @
		link @
		List.map gen_entry feed.entries)