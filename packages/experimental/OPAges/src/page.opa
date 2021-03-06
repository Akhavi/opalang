/*
    Copyright Â© 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA.  If not, see <http://www.gnu.org/licenses/>.
*/


package opages
import opace
import stdlib.crypto
import stdlib.web.template
import stdlib.web.client
import stdlib.upload
import stdlib.widgets.tabs
import stdlib.widgets.hlist
import stdlib.widgets.core
import stdlib.widgets.notification

/**
 * {1 About this module}
 * This module provides a function for build an xhtml administration
 * interface, with this interface OPAges administrator can add, edit,
 * remove... OPAges resources. [Page] module provides also a resources
 * function that be able to returns resources added by administrator
 * or it build default error resource.
 */

/**
 * {1 Types defined in this module}
 */

type Page.env = {
  current_url : string
}

/**
 * A configuration for initialize a page entity
 */
type Page.config('a, 'b) = {
  access : Page.config.access
  engine : Page.env -> Template.engine('a, 'b)
}

type Page.config.access = {

  /** Read function of stored datas. */
  select : (
      /** Return the last version of page. */
      {last : string} /

      /** Return the published version of page. */
      {published : string} /

      /** Return the [rev] revision of page. */
      {key : string rev : int}
    ) -> option({rev : int page : Page.stored})

  /** Write function on stored datas. */
  save : (
      /** Save a new page revision */
      {key : string page : Page.stored} /

      /** Set [publish] as publihed revision. */
      {key : string publish : Page.published}
    ) -> int

  /** Return info on the published page. */
  published : string -> option(Page.published)

  /** Remove page stored on corresponding key. */
  rm  : string -> void

  /** List all of stored key associated to corresponding published
      page. */
  ls : -> list((string, option(Page.published)))

  /** Return list of all page stored at given key. (Last stored page
      as first element of list). */
  history : string -> list(Page.stored)

}

/**
 * Define what is a page.
 * - embedded means that the page should be embedded in the applications.
 * - resource is a subset of [resource] that be able to store in database.
 */
type Page.t =
  {embedded : {head : xhtml body : xhtml}} /
  {resource : resource}

type Page.manager = {
  admin: string, string -> xhtml
  resource: string -> Page.t
  resource_with_env: string, Page.env -> Page.t
  try_resource: string -> option(Page.t)
  source : string -> option(string)
}

/**
 * Type of data stored in database
 */
type Page.stored_content =
  {image : image} /
  {css   : string} /
  {source : string mime : string} /
  {binary : binary mime : string} /
  /* Contains sourced template */
  {hcontent : string
   bcontent : string}

@abstract type Page.stored =
  {author : string
   content : Page.stored_content
   date : Date.date
   parent : int}

@abstract type Page.published =
   {author : string
    rev : int
    date : Date.date}
/**
 * A record used for give some primitive to the admin GUI unless
 * publish critical primitives.
 */
@private type Page.access = {
  save : string, Page.stored_content,option(int) -> int
  set_rev : string,  int -> void
  get : string -> option((Page.stored,int))
  get_edit : string -> Page.edit
  get_rev_number : string -> Page.published
  remove : string -> void
  list : -> list((string,Page.published,bool))
  history_list : string -> list((string, Date.date, int))
  history_edit : string, int -> option(Page.edit)
}

@private type Page.notify = {
  subscribe : ({event : Page.Notification.event by : string} -> void) -> void
  subscribe_with : string,({event : Page.Notification.event by : string} -> void) -> void
  send    :  Page.Notification.event -> void
}

@private type Page.locker = {
  release : string -> Page.Lock.return
  try : string -> Page.Lock.return
  check : string -> Page.Lock.return
  force_release : string -> Page.Lock.return
}

@private type Page.full_access = {
  access : Page.access
  notify : Page.notify
  locker : Page.locker
}

@private type Page.edit =
  {image}
/ {binary
   mime:string
   save:{mime:string} -> int
   set_preview:{mime:string} -> void}
/ {source : string; mime : string}
/ {css : string}
/ {hsource : string
   bsource : string
   save_template : {hsource : string; bsource : string} -> ({fail:Template.failure} / {rev:int})
   preview_template : {hsource : string; bsource : string} -> option(Template.failure)}

type Page.Notification.event =
  {connect}
/ {publish : (string,int)}
/ {open : string}
/ {save : string}
/ {remove : string}
/ {lock : string}
/ {release : string}
/ {talk : string}

type Page.Lock.return = outcome(
  {lock_at:Date.date by : string},

  {internal_error}
/ {locked : {lock_at : Date.date by : string lock_by : ThreadContext.client}}
/ {unlocked}
)


Page = {{

  /**
   * {2 Privates preview utils}
   */

  @server @private preview_context = UserContext.make(StringMap.empty:stringmap(Page.stored_content))

  @server @private set_preview(key,page) =
    UserContext.change(StringMap.add(key,page,_), preview_context)

  @server @private has_preview(key) =
    UserContext.execute(StringMap.mem(key,_), preview_context)

  @server @private get_preview(key) =
    UserContext.execute(StringMap.get(key,_), preview_context)

  @server @private del_preview(key) =
    UserContext.change(StringMap.remove(key,_), preview_context)

  /**
   * {2 Privates utils}
   */
  /**
   * Get mode corresponding to the [file].
   */
  @private get_suffix(file) =
    match file with
    | "" | "/" -> some("html")
    | _ -> x = Parser.try_parse(Rule.has_suffix(Rule.alphanum_string), file)
           Option.map((x -> x.f2), x)

  @private template_config = { Template.default_conf with fallback_to_text_node = false }

  @private lock_message(r:Page.Lock.return) = match r
    | {success = ~{lock_at by}} -> "Success : lock at {Date.to_string(lock_at)} by {by}"
    | {failure = {internal_error}} -> "Failure : lock internal error"
    | {failure = {unlocked}} -> "Failure : seems already unlocked"
    | {failure = {locked = ~{lock_at lock_by by}}} ->
      "Failure : already locked at {Date.to_string(lock_at)} by {by}    (with context {lock_by})"

  @private
  search_dead_link_for_resource(access : Page.full_access , resource_id):option(list(string)) = (
    inside_href_parser = (parser | t=((!"\"" .)+) -> Text.to_string(t))
    href_parser = (parser | "href=\"" url=inside_href_parser "\"" -> url)
    sep = (parser | (!"href=\"" .)+ -> void)
    link_parser = (parser | lst={Rule.parse_list_sep(true, href_parser, sep)} sep  -> lst)
    Option.switch( ({content=stored author=_ date=_ parent=_},_) ->
      match stored with
      | { ~bcontent; hcontent=_ } -> Parser.try_parse(link_parser, bcontent)
      | _ -> none
      , none
      , access.access.get(resource_id))
    )

  @private
  fetch_dead_links(access : Page.full_access) : stringmap(list(string)) = (
    List.foldl((el,_,_), acc ->
      do Log.debug("Admin", "Search for dead links in {el}")
      match search_dead_link_for_resource(access, el) with
      | { ~some } -> StringMap.add(el,some, acc)
      | {none } -> acc
    , access.access.list()
    , StringMap_empty )
  )

  make_absolute(file, special) =
    // Add the starting /
    file = match String.index("/", file)
    {some=0} -> file
    _ -> if special then file else "/{file}"
    // Remove the ending /
    len = String.length(file)
    file = if String.get(len-1, file) == "/" then
      String.substring(0, len-1, file)
    else file
    file

  /**
   * {2 Database access}
   */

  //Hack because we no slicer annot on functor
  @client @private get_listener() =
    handler(state, msg) = match msg
      | ~{handler} -> {set = Map.add(Dom.fresh_id(),handler,state)}
      | ~{handler id} -> {set = Map.add(id,handler,state)}
      | ~{remove} -> {set = Map.remove(remove,state) }
      | ~{event by} -> do Scheduler.push(-> Map.iter(_,handler -> handler(~{event by}), state)) {unchanged}
    Session.make(Map.empty, handler)

  @server @private ServerAccess(~{engine access=caccess}:Page.config('a, 'b)) = {{

    /**
     * Network used for the notification systemp
     */
    network = Network.empty()
      : Network.network(
          { by: string; event: Page.Notification.event }
        / { handler: { by: string; event: Page.Notification.event } -> void }
        / { id : string ; handler: { by: string; event: Page.Notification.event } -> void }
        / { remove : string}
      )

    /**
     * {2 Notification system + Lock system for one user}
     */
    Notification_Lock =
      lock_cell = Cell.make(StringMap.empty,
        (map, message ->
          by = message.by
          match message.action
          | ~{lock} ->
            match StringMap.get(lock, map)
            | ~{some} -> match ThreadContext.get({current}).key
              | ~{client} ->
                if client == some.lock_by then
                  {return = {success={lock_at = some.lock_at ~by}} instruction = {unchanged}}
                else
                  {return = {failure={locked = some}} instruction = {unchanged}}
              | _ -> {return = {failure={locked = some}} instruction = {unchanged}}
              end
            | {none} -> match ThreadContext.get({current}).key
              | {client=lock_by} ->
                lock_at = Date.now()
                {return = {success=~{lock_at by}}
                 instruction = {set = StringMap.add(lock, ~{by lock_by lock_at}, map)}}
              | _ -> {return = {failure={internal_error}} instruction = {unchanged}}
              end
            end
          | ~{unlock force} ->
            match StringMap.get(unlock, map)
            | {none}  -> {return = {failure={unlocked}} instruction = {unchanged}}
            | ~{some} -> match ThreadContext.get({current}).key
              | ~{client} ->
                if force || client == some.lock_by then
                  {return = {success={lock_at = some.lock_at ~by}}
                   instruction = {set = StringMap.remove(unlock, map)}}
                else
                  {return = {failure={locked = some}}
                   instruction = {unchanged}}
              | _ -> {return = {failure={internal_error}} instruction = {unchanged}}
              end
            end
          | ~{check} ->
            match StringMap.get(check, map)
            | ~{some} -> match ThreadContext.get({current}).key
              | ~{client} ->
                if client == some.lock_by then
                  {return = {success={lock_at = some.lock_at ~by}} instruction = {unchanged}}
                else
                  {return = {failure={locked = some}} instruction = {unchanged}}
              | _ -> {return = {failure={internal_error}} instruction = {unchanged}}
              end
            | {none} -> {return = {success={lock_at = Date.now() ~by}} instruction = {unchanged}}
        )
      )
      by ->
        Notification = {{

          @private client_listener =
            r = Mutable.make(none)
            -> match r.get()
               | {none} ->
                 c = get_listener()
                 do r.set({some = c})
                 do Network.add(c, network)
                 c
               | ~{some} -> some



          send(event:Page.Notification.event) =
            Network.broadcast(~{event by}, network)

          subscribe(handler) = Session.send(client_listener(), ~{handler})

          subscribe_with(id,handler) = Session.send(client_listener(), ~{handler id})

        }}
        Lock = {{
          @private wrap(x) = {action=x ~by}

          @private wrap_result(event, result) = match result
            | {success=_} -> do Notification.send(event) result
            | _ -> result

          try(url) = wrap_result({lock=url}, Cell.call(lock_cell, wrap({lock=url})))

          release(url) = wrap_result({release=url}, Cell.call(lock_cell, wrap({unlock=url force=false})))

          force_release(url) = wrap_result({release=url}, Cell.call(lock_cell, wrap({unlock=url force=true})))

          check(url) = Cell.call(lock_cell, wrap({check=url}))
        }}
        (Notification, Lock)

    access(user) : Page.access    =
      get(key) : option((Page.stored,int)) = Option.map(~{page rev} -> (page, rev), caccess.select({published = key}))

      save(key, page : Page.stored_content, rev_opt) : int =
        caccess.save(~{key page = {author=user content=page date=Date.now() parent=(rev_opt ? -1)}})

      remove(key) = caccess.rm(key)

      list() = List.map((x,p) -> (x, p ? Page.not_published, has_preview(x)) ,caccess.ls())

      save_as_template(key, ~{hsource bsource}, rev_opt) =
        engine = engine({current_url=""})
        match Template.try_parse_with_conf(template_config, engine, hsource)
        | ~{failure} -> {fail=failure}
        | {success = hcontent} ->
          match Template.try_parse_with_conf(template_config, engine, bsource)
          | ~{failure} -> {fail=failure}
          | {success = bcontent} ->
            hcontent = Template.to_source(engine, hcontent)
            bcontent = Template.to_source(engine, bcontent)
            do Log.notice("PageDebug", "Saving headers {hcontent}")
            rev=save(key, ~{hcontent bcontent}, rev_opt)
            {~rev}

    preview_template(key, ~{hsource bsource}) =
      engine = engine({current_url=""})
      match Template.try_parse_with_conf(template_config, engine, hsource)
      | ~{failure} -> some(failure)
      | {success = h} ->
        match Template.try_parse_with_conf(template_config, engine, bsource)
        | ~{failure} -> some(failure)
        | {success = b} ->
          page = {hcontent=Template.to_source(engine, h)
                  bcontent=Template.to_source(engine, b)
                 }:Page.stored_content
          do set_preview(key, page)
          none

      make_edit(key, {content=stored date=_ author=_ parent=_} : Page.stored, rev) = match stored
        | {image=_} -> {image}
        | {css=_} as k
        | {source=_ mime=_} as k -> k
        | ~{binary mime} ->
          save(~{mime}) = save(key, ~{binary mime}, some(rev))
          set_preview(~{mime}) = set_preview(key, ~{binary mime})
          {binary ~mime ~save ~set_preview}
        | ~{hcontent bcontent} ->
          {
            hsource = hcontent
            bsource = bcontent
            save_template = save_as_template(key, _, some(rev))
            preview_template = preview_template(key, _)
          } : Page.edit


      get_edit(key):Page.edit =
        match caccess.select({last = key}) with
        | {some=~{rev page}} -> make_edit(key, page, rev)
        | {none} ->
          match get_suffix(key)
          | {some="html"} | {some = "xmlt"}-> {
              hsource = "<!-- Enter your headers here -->"
              bsource = "<!-- Enter your body here --> "
              save_template = save_as_template(key, _, none)
              preview_template = preview_template(key, _)
            }
          | {some="css"} -> {css = "/* Enter your css here */"}
          | _ -> {source = "A custom resource" mime="text/plain"}

      history_list(key) = List.map(~{author date parent ...} -> (author, date, parent), caccess.history(key))

      history_edit(key, rev) = Option.map(~{rev page} -> make_edit(key, page, rev), caccess.select(~{key rev}))

      set_rev(key, rev) = ignore(caccess.save(~{key publish = {author=user ~rev date=Date.now()}}))

      get_rev_number(key) = caccess.published(key) ? Page.not_published

      ~{save get get_edit remove list history_edit history_list
        set_rev get_rev_number
       }

    full(user) =
      (Notification, Lock) = Notification_Lock(user)
      { access = access(user)
        locker = {
          try=Lock.try
          release=Lock.release
          force_release=Lock.force_release
          check=Lock.check
        } : Page.locker
        notify = {
          subscribe = Notification.subscribe
          subscribe_with = Notification.subscribe_with
          send = Notification.send
        } : Page.notify
      }

  }}

  /**
   * {2 Graphical user interface (admin)}
   */
  /**
   * This modules provides a build function for administration
   * interface.
   */
  @private AdminGui = {{

    /** Just a simple string transformation for xhtml insert. */
    @private file_for_xhtml =
      | "" | "/" -> "/"
      | x -> x

    /** A translation that allows to use file on dom identifiers. */
    @private file_id = Crypto.Hash.md5
    @private buffer_file_id(file) = "admin_buffer_{file_id(file)}"
    @private navigator_file_id(file) = "admin_files_navigator_{file_id(file)}"
    @private file_line_preview(file) = "admin_files_navigator_preview{file_id(file)}"
    @private file_line_edit(file) ="admin_files_navigator_edit{file_id(file)}"
    @private file_line_publish(file) ="admin_files_navigator_publish{file_id(file)}"

    /** Tabs. */

    tabs_file_id = "tabs_file"

    @private @client
    on_tab_select(_num:int, tab:WTabs.tab) =
      match tab.custom_data
      {some=(file)} ->
        bid = navigator_file_id(file)
        do Dom.trigger(#{bid}, {click})
        true
      _ -> false
    @private @client on_tab_add(num:int, tab:WTabs.tab) =
      match tab.custom_data
      {some=(file)} ->
        fid = navigator_file_id(file)
        do Dom.set_property_unsafe(Dom.select_id(fid), "tab", "{num}")
        some(tab)
      _ -> none
    @private @client on_tab_remove(_num:int, tab:WTabs.tab) =
      match tab.custom_data
      {some=(file)} ->
        id = buffer_file_id(file)
        fid = navigator_file_id(file)
        do Dom.set_property_unsafe(Dom.select_id(fid), "tab", "")
        // do access.notify.remove(id)
        do Dom.remove(#{id})
        do del_preview(file)
        do file_line_set_edit(file, false)
        true
      _ -> true
    @private @both insert_pos = {at_end}:WTabs.pos
    @private @both delete_pos = {after_select}:WTabs.pos
    @private @both
    tabs_config = {
      WTabs.default_config_with_css(tabs_file_id) with
        ~insert_pos
        ~delete_pos
        on_add=on_tab_add
        on_select=on_tab_select
        on_remove=on_tab_remove
        add_text=none
    } : WTabs.config
    @private
    tabs_html() = WTabs.html(tabs_config, tabs_file_id, [])

    @client
    add_tab(file : string, title : string) =
      do Log.info("[add_tab]", "{title} {file}")
      tab = WTabs.make_tab(
              _ -> WTabs.make_constant_content(title),
              true, true, false, some(file), tabs_config.remove_text, none)
      do WTabs.insert_tab(tabs_config, tabs_file_id, tab)
      void

    /** File navigator. */

    admin_files_id = "admin_files"

    on_file_remove(key) =
      do Log.info("[on_remove]", "{key}")
      li_id = WHList.item_id(admin_files_id, key)
      do Log.info("[on_remove]", "{li_id}")
      //li = Dom.select_id(li_id)
      li_sons = WHList.item_sons_class(admin_files_id)
      sons = Dom.select_children(Dom.select_raw("li#{li_id} > ul > li.{li_sons} > ul"))
      do Log.info("[on_remove]", "Sons : {sons}")
      Dom.is_empty(sons)

    file_stringify(x:string) = "{x}"
    file_config = {
      WHList.default_config_with_css(admin_files_id) with
      helper = {
        stringify = file_stringify
        father = _ -> none
      }
      on_remove=on_file_remove
    } : WHList.config

    @private file_line_set_preview(file,b) =
      s = if b then "[preview]" else ""
      Dom.set_text(#{file_line_preview(file)},s)

    @private file_line_set_publish(file,pub_opt) =
      s = match pub_opt with | {~some} -> " [pub #{some}]" | {none} -> ""
      Dom.set_text(#{file_line_publish(file)},s)

    @private file_line_set_edit(file, force) =
      id = buffer_file_id(file)
      buf = Dom.select_raw("#{id} #{id}_select}")
      s = if (Dom.is_empty(buf) || Dom.is_enabled(buf)) && not(force) then "" else "[editing]"
      Dom.set_text(#{file_line_edit(file)},s)

    @private file_line_content(_access:Page.full_access, name, file, published_rev, preview) =
      id = buffer_file_id(file)
      <span>
        {file_for_xhtml(name)}
        <span id={file_line_publish(file)} >{match published_rev with | {~some} -> " [pub #{some}]" | {none} -> ""}</span>
        <span id={file_line_preview(file)} >{if preview then"[preview]" else ""}</span>
        <span id={file_line_edit(file)} >{
         buf = Dom.select_raw("#{id} #{id}_select}")
         if (Dom.is_empty(buf) || Dom.is_enabled(buf)) then "" else "[editing]"
        }</span>
      </span>

    @client
    toggle_file_sons(file, force) =
      key = navigator_file_id(file)
      li_id = WHList.item_id(admin_files_id, key)
      li_sons = WHList.item_sons_class(admin_files_id)
      sons = Dom.select_raw("li#{li_id} > ul > li.{li_sons}")
      ssons = Dom.select_raw("li#{li_id} > ul > li.{li_sons} > ul > li")
      do Dom.toggle_class(#{li_id}, "toggled")
      // do Dom.toggle(sons) // does not seem to work as expected
      do if Dom.has_class(#{li_id}, "toggled") then
        do Dom.hide(sons)
        if Dom.length(ssons) > 0 || force then
          _ = Dom.set_text(#{"{navigator_file_id(file)}_toggle"}, "+")
          void
        else
          _ = Dom.set_text(#{"{navigator_file_id(file)}_toggle"}, "")
          void
      else
        do Dom.show(sons)
        _ = Dom.set_text(#{"{navigator_file_id(file)}_toggle"}, "-")
        void
      do Log.info("[toggle_file_sons]","toggle {file}")
      void

    /** Create a file line for table insert. */
    @private file_line(access:Page.full_access, opened, name, file, published_rev, preview) =
      class = if opened then "on" else "off"
      <span class="{class}"
            id="{navigator_file_id(file)}"
            onclick={_ ->
              do Log.info("[file_line]", "click")
              Action.open_file(access, file, published_rev)}
            options:onclick={[{stop_propagation}]}>
        {file_line_content(access, name, file, published_rev, preview)}
      </span>

    /** Insert if necessary a file line into files navigator. */
    @private file_line_insert(access, opened, file_uri, published_rev, preview, collapse) =

      match file_uri
      {none} -> void
      {some=uri} ->

        match uri
        ~{fragment is_directory is_from_root path query} ->
          path = if is_from_root then ["" | path] else path
          is_from_root = false
          do Log.info("[file_line_insert]", "Path {path}")

          _ = List.fold(
            e, acc ->
              file = Uri.to_string({~fragment ~is_directory ~is_from_root path=List.rev([e|acc]) ~query})
              key = navigator_file_id(file)
              f = if file == "" then "/" else file
              content = file_line(access, opened, e, f, published_rev, preview)
              value =
                <div>
                  <span id="{navigator_file_id(file)}_toggle" onclick={_->
                    toggle_file_sons(file, false)}
                    options:onclick={[{stop_propagation}]}/>
                  {content}
                </div>
              item = WHList.make_item(
                {title=e ~value},
                {selected=opened; checked=false},
                {selectable=true; checkable=false; no_sons=false}
              )
              do Log.info("[file_line_insert]", "Insert {file} {key} in {List.rev(acc)}")
              file_config = { file_config with
                helper = {
                  stringify = file_stringify
                  father = _ ->
                    if acc == [] then none
                    else
                      father_file = Uri.to_string({~fragment ~is_directory ~is_from_root path=List.rev(acc) ~query})
                      ff = navigator_file_id(father_file)
                      do Log.info("[file_line_insert]", "father file: {father_file} {ff}")
                      some(ff)
                }
              }
              do match WHList.insert_item(file_config, admin_files_id, key, item, none, false) with
              ~{some} ->
                do Log.info("[file_line_insert]", "Insert OK @{some}")
                do if collapse && List.length(acc) > 0 then
                  toggle_file_sons(file, true)
                else void
                void
              {none} ->
                _ = WHList.select_item(file_config, admin_files_id, key, false)
                Log.info("[file_line_insert]", "Insert KO {key}")
              [e|acc]
            , path, []
          )

          void
        _ -> void

    /**
     * Build a buffer and insert it on dom node with identifier
     * [id]. The buffer can be specialized according to file
     * extension.
     *
     * Note : Client side function because need dom access.
     */
    @client build_buffer(access, file, id) =
      do access.notify.send({open = file})
      select_id = "{id}_select"
      error_id = "{id}_error"
      lock_button_id = "{id}_button_lock"
      save_button_id = "{id}_button_save"
      draft_id = "{id}_draft"
      preview_id = "{id}_preview"

      editor_id = "{id}_editor"
      reporting_id = "{id}_reporting"
      command_id = "{id}_command"
      published_id = "{id}_published"
      buffer_mime_id = "{id}_mime_container"

      /* Error reporting */
      build_reporting() = Dom.transform([#{reporting_id} <- <div id={error_id}/>])

      do_report(msg:xhtml) = ignore(Dom.put_inside(Dom.select_id(error_id), Dom.of_xhtml(msg)))

      /* Generate some buttons */

      /* Generate ace buffer */
      common_ace_init(id_buffer, class, content, mode) =
        html = <div id={id_buffer} class={class}/>
        _ = Dom.transform([#{editor_id} +<- html])
        ace = Ace.edit(id_buffer)
        do Option.iter(x -> ignore(Ace.set_mode(ace, x)), mode)
        _ = Ace.set_content(ace, content)
        do Ace.move_cursor(ace, 0, 0)
        do Ace.read_only(ace, false)
        ace

      on_ok_preview(f) =
        do do_report(<></>)
        _ = Client.winopen(file, {_blank},[], false)
        _ = f()
        void

      /* Generate history selector */
      rec build_pub_version(_rev : option(int)) =
        xhtml =
          <span> Published revision : {r = access.access.get_rev_number(file)
                                      if r.rev == -1
                                      then "none"
                                      else "{r.rev} - {Date.to_formatted_string(Date.date_only_printer, r.date)} @ {Date.to_formatted_string(Date.time_only_printer, r.date)} by {r.author}"}</span>
        Dom.transform([#{published_id} <- xhtml])
      and draft()=
        do Dom.show(#{draft_id})
        do Dom.set_enabled(#{select_id},false)
        do Dom.set_enabled(#{save_button_id},true)
        do file_line_set_edit(file, false)
        void
      and make_buttons(rev : option(int),action) =
        get_selected_rev() =
            Int.of_string(Dom.get_value(Dom.select_id(select_id)))
        action_change_rev(_:Dom.event)=
          if Dom.get_property(#{select_id},"disable")=={some="true"}
          then void
          else
            do build_buffers(some(get_selected_rev()))
            file_line_set_edit(file, false)
        action_set_rev(_:Dom.event) =
          rev = get_selected_rev()
          do access.notify.send({publish=(file,rev)})
          do access.access.set_rev(file, rev)
          do build_buffers(some(rev))
          build_pub_version(some(rev))

        /* Build the select input, for selecting file revisions */
        build_select(rev) =
          hist = access.access.history_list(file)
          size = List.length(hist)
          r = access.access.get_rev_number(file)
          /* Build the map of revisions,
             Each cell contains :
             - its author
             - its date
             - its parent revision
             - its sons revision

             /!\ Note that the keys in DB starts at 1 and not 0 /!\
             -- Those who do not have parents have the -1 parent, aka root --

             @TODO: should be cached maybe? */
          //do Log.info("history", "{hist}")
          make_map(i, (author, date, parent), acc) =
            i = i+1 // Use the same key as in DB
            //do jlog("map {i} - {parent}")
            acc = IntMap.add(i, (author, date, parent, []), acc)
            match IntMap.get(parent, acc)
            {some=(author, date, par, sons)} -> IntMap.add(parent, (author, date, par, [i|sons]), acc)
            _ -> IntMap.add(parent, (author, date, -1, [i]), acc)
          map = List.foldi(make_map, hist, IntMap.empty)

          do Log.info("map", "-- begin revision map")
          do IntMap.iter(k, v -> Log.info("map", "{k} -> {v}"), map)
          do Log.info("map", "-- end revision map")

          /* Build one revision of the file for the select input */
          build_rev(key, (author, date, parent, sons), (acc, pad)) =
            i = key
            based = "" // if parent < 0 then "" else " based on {parent}"
            pad = String.repeat(pad, "-")
            value = "{pad}#{i} | {Date.to_formatted_string(Date.date_only_printer, date)} @ {Date.to_formatted_string(Date.time_only_printer, date)} by {author}{based}"
            value = if r.rev == i then value ^ " [pub]" else value
            value = if size == i then value ^ " [last]" else value
            default(i : int) : xhtml = (<option value="{i}">{value}</option>)
            selected(i : int) : xhtml = (<option value="{i}" selected="selected">{value}</option>)
            res = match rev
            | {none} ->    if i == size then selected(i) else default(i)
            | {some=rev} ->if i == rev  then selected(i) else default(i)
            [res|acc]

          /* Auxiliary function for building revision.
             First treat the parent revision, then folds on its sons.
             There will be a padding if the parent revision has more than one sons */
          rec aux(map, rev, (acc, pad, p_sons_len)) =
            match IntMap.get(rev, map)
            {some=(author, date, parent, sons)} ->
              //do jlog("rev {rev}")
              acc = if rev < 0 then acc else build_rev(rev, (author, date, parent, sons), (acc, pad))
              len = List.length(sons)
              pad = if p_sons_len > 1 || len > 1 then pad+1 else pad
              List.fold(
                rev_son, acc -> aux(map, rev_son, (acc, pad, len))
              , sons, acc)
            _ -> acc

          /* Build the file revisions list,
             we know the root is revision 1 because no revision is deleted */
          build_revisions(map) =
            aux(map, -1, ([], 0, 0))

          <select id={select_id} onchange={action_change_rev}>
            {build_revisions(map)}
          </select>

        buttons =
          common = <>
            <button type="button"
                    onclick={Action.remove_file(access, file)}>Remove</button>
          </>
          match action with
          | {some = action} ->
              make_lock_button(lock, x) =
                <button type="button" id={lock_button_id}
                        onclick={lock}>{x}</button>
              rec val lock_button = make_lock_button(action_try_lock, "Lock")
              and val unlock_button = make_lock_button(action_release, "Release")
              and val force_unlock_button = make_lock_button(action_force_release, "Force Release")
              and action_try_lock(_:Dom.event) =
                result = access.locker.try(file)
                do do_report(<>{lock_message(result)}</>)
                match result
                | {success=_} ->
                  do ignore(Dom.put_replace(Dom.select_id(lock_button_id),
                                            Dom.of_xhtml(unlock_button)))
                  do Dom.set_enabled(Dom.select_id(save_button_id), true)
                  action.read_only(false)
                | _ ->
                  do Dom.set_enabled(Dom.select_id(save_button_id), false)
                  do ignore(Dom.put_replace(Dom.select_id(lock_button_id),
                                            Dom.of_xhtml(force_unlock_button)))
                  action.read_only(true)
              and action_release(_:Dom.event) =
                result = access.locker.release(file)
                do do_report(<>Release {lock_message(result)}</>)
                _ =  Dom.put_replace(Dom.select_id(lock_button_id),
                                   Dom.of_xhtml(lock_button))
                do Dom.set_enabled(Dom.select_id(save_button_id), true)
                do action.read_only(false)
                void
              and action_force_release(_:Dom.event) =
                result = access.locker.force_release(file)
                do do_report(<>{lock_message(result)}</>)
                do Dom.set_enabled(Dom.select_id(save_button_id), true)
                do ignore(Dom.put_replace(Dom.select_id(lock_button_id),
                                            Dom.of_xhtml(lock_button)))
                do action.read_only(false)
                void
              and make_preview_button(action,title)=
                 <button type="button" id="{preview_id}" onclick={action}>
                   {title}
                 </button>
              and val start_preview = make_preview_button(_->action_start_preview(),"Start Preview")
              and val stop_preview = make_preview_button(_->action_stop_preview(), "Stop Preview")
              and action_start_preview() =
                f() =
                  do file_line_set_preview(file, true)
                    Dom.put_replace(Dom.select_id(preview_id),
                                    Dom.of_xhtml(stop_preview))
                _ = action.preview(f)
                void
              and action_stop_preview() =
                do del_preview(file)
                do file_line_set_preview(file, false)
                _ = Dom.put_replace(Dom.select_id(preview_id),
                                   Dom.of_xhtml(start_preview))
                void

              do access.notify.subscribe_with(id,
                   | {event={~lock} ~by} ->
                     if lock != file || Outcome.is_success(access.locker.check(file)) //so bad
                     then void else
                     b = Dom.select_id(save_button_id)
                     do Dom.set_enabled(b, false)
                     do action.read_only(true)
                     _ =  Dom.put_inside(b, Dom.of_xhtml(<>Save : (locked by {by})</>))
                     do ignore(Dom.put_replace(Dom.select_id(lock_button_id),
                                            Dom.of_xhtml(force_unlock_button)))
                     void
                   | {event={~release} by=_} -> if release != file then void else
                     b = Dom.select_id(save_button_id)
                     do Dom.set_enabled(b, true)
                     do action.read_only(false)
                     _= Dom.put_inside(b, Dom.of_xhtml(<>Save</>))
                     do ignore(Dom.put_replace(Dom.select_id(lock_button_id),
                                            Dom.of_xhtml(lock_button)))
                     void
                   | {event={publish=(mfile,rev)} by=_ } -> if mfile != file then void else
                     build_pub_version(some(rev))
                   | {event={~save} by=_} -> if save != file then void else
                     build_pub_version(rev)
                   | _ -> void
                 )
            <>
              <div>Selected Revision <span style="display:none" id=#{draft_id}>--Draft--</span>: {build_select(rev)}</div>
              <div class="button_group" style="display:inline-block; margin-right:40px" >
                {match access.locker.check(file)
                 | {success = _} ->
                   <button type="button"
                           id={save_button_id}
                           onclick={_ ->
                             do Dom.set_enabled(#{save_button_id}, false)
                             _ = action.save()
                             file_line_set_edit(file, false)} >Save</button>
                 | ~{failure} ->
                   by = match failure | {locked = {~by ...}} -> by | _ -> "501??!!??"
                   <button type="button"
                     disabled="disabled"
                     id={save_button_id}
                     onclick={_ ->
                       do Dom.set_enabled(#{save_button_id}, false)
                       _ = action.save()
                       file_line_set_edit(file, false)}>Save (locked by {by})</button>
                }
                <button type="button" onclick={action_change_rev}> Discard change </button>
                <button type="button"
                        onclick={action_set_rev}>Publish</button>
              </div>

              {if has_preview(file)
               then stop_preview
               else start_preview}

              <div class="button_group" style="display:inline-block; margin-right:40px">
                {match access.locker.check(file)
                 | {success = _} -> lock_button
                 | {failure=_} -> force_unlock_button
                }
              </div>
              <div class="button_group" style="display:inline-block; margin-right:40px">
                {common}
              </div>
            </>
          | {none} -> common
        Dom.transform([#{command_id} <- buttons])

      and build_buffers(rev : option(int)) =
        //do Log.info("build_buffers","{rev}")
        edit = match rev
          | {none} -> access.access.get_edit(file)
          | {some=rev} -> Option.get(access.access.history_edit(file, rev))
        match edit with
        | {image} ->
          dom = Dom.of_xhtml(<img src="{file}"/>)
          _ = Dom.put_at_end(Dom.select_id(id), dom)
          make_buttons(rev,none)
        | {binary ~mime ~save ~set_preview} ->
          mime_id = "mime_{id}"
          save() =
            rev = save({mime = Dom.get_value(Dom.select_id(mime_id))})
            do access.notify.send({save = file})
            do Dom.set_enabled(#{save_button_id},true)
            do do_report(<>Save binary success -> rev {rev}</>)
            do build_buffers(some(rev))
            void
          x = <>
                Uneditable binary file, Mimetype
                <input type="text" id="{mime_id}" value="{mime}" onkeypress={_ -> draft()} onnewline={_ -> save()}/>
              </>
          do Dom.transform([#{buffer_mime_id} <- x])
          make_buttons(rev,some({
              ~save
              read_only(_) = void
              preview(f) =
                page = {mime = Dom.get_value(Dom.select_id(mime_id))}
                do set_preview(page)
                on_ok_preview(f)
            }))
        | ~{source mime} ->
          /* A raw resource editor is an ace editor + an input for mime */
          id_src = "{id}_src"
          id_mime = "{id}_mime"
          ace = common_ace_init(id_src, ["admin_editor_source"], source, none)
          /* Buffer buttons */
          get_mime() =
            x = Dom.get_value(Dom.select_id(id_mime))
            x
          do Ace.add_event_listener(ace, {change}, draft)
          do make_buttons(rev,some({
               save() =
                 rev = access.access.save(file, {source=Ace.get_content(ace) mime=get_mime()},rev)
                 do access.notify.send({save = file})
                 do build_buffers(some(rev))
                 do do_report(<>Save source success -> rev {rev}</>)
                 Dom.set_enabled(#{save_button_id},false)

               read_only(b) = Ace.read_only(ace, b)
               preview(f) =
                fail()=
                   page = {source=Ace.get_content(ace)
                           mime=get_mime()}
                   set_preview(file, page)

                rec val timer = Scheduler.make_timer(1000, -> Session.send(sess,void))
                and val sess = Session.make(Date.now(),(last_date,_ -> now= Date.now()
                                                        do Log.info("d","preview update")
                                                        do
                                                          if Date.compare(Date.advance(last_date,Duration.s(2)),Date.now())=={lt}
                                                          then
                                                            do Log.info("d","preview timer stop")
                                                            _ = fail()
                                                            timer.stop()
                                                          else Log.info("d","preview update")
                                                        {set=now}
                                                         ))
                do Log.info("d","preview first start timer")
                do Ace.add_event_listener(ace, {change}, -> do timer.stop() timer.start())
                do fail()
                on_ok_preview(f)
            }))
          input = <input type="text" value="{mime}" id="{id_mime}" onkeypress={_ -> draft()}/>
          do Dom.transform([#{buffer_mime_id} <- <>Mimetype: {input}</>])
          void
        | ~{css} ->
          /* Css editor is just a simple ace editor */
          id_css = "{id}_css"
          ace = common_ace_init(id_css, ["admin_editor_css"], css, some("css"))
          do Ace.add_event_listener(ace, {change}, draft)
          make_buttons(rev,some({
              save() =
                rev = access.access.save(file, {css=Ace.get_content(ace)}, rev)
                do access.notify.send({save = file})
                do build_buffers(some(rev))
                do do_report(<>Save css success -> rev {rev}</>)
                Dom.set_enabled(#{save_button_id},false)
              read_only(b) = Ace.read_only(ace, b)
              preview(f) =
                fail()=
                  page = {css=Ace.get_content(ace)}
                  set_preview(file, page)
                rec val timer = Scheduler.make_timer(1000, -> Session.send(sess,void))
                and val sess = Session.make(Date.now(),(last_date,_ -> now= Date.now()
                                                        do Log.info("d","preview update")
                                                        do
                                                          if Date.compare(Date.advance(last_date,Duration.s(2)),Date.now())=={lt}
                                                          then
                                                            do Log.info("d","preview timer stop")
                                                            _ = fail()
                                                            timer.stop()
                                                          else Log.info("d","preview update")
                                                        {set=now}
                                                         ))
                do Log.info("d","preview first start timer")
                do Ace.add_event_listener(ace, {change}, -> do timer.stop() timer.start())
                do fail()
                on_ok_preview(f)
            }))
        | ~{hsource bsource save_template preview_template} ->
          /* Html embedded editor is divided in two ace editor, one for
          headers another for body */
          head_id = "{id}_headers"
          body_id = "{id}_body"
          /* Head ace */
          ace_head = common_ace_init(head_id, ["admin_editor_html_header"],
                                          hsource, some("html"))
          /* Body ace */
          ace_body = common_ace_init(body_id, ["admin_editor_html_body"],
                                          bsource, some("html"))

          do Ace.add_event_listener(ace_body, {change}, draft)
          do Ace.add_event_listener(ace_head, {change}, draft)
          /* Buffer buttons */
          do make_buttons(rev,
            some({
              save() =
                fail = save_template({
                  hsource = Ace.get_content(ace_head)
                  bsource = Ace.get_content(ace_body)
                })
                match fail with
                | {~rev} ->
                  do access.notify.send({save = file})
                  do build_buffers(some(rev))
                  do do_report(<>Save hsource success -> rev {rev}</>)
                  Dom.set_enabled(#{save_button_id},false)
                | {~fail} ->
                  do Dom.set_enabled(#{save_button_id},true)
                  do_report(<>{"{fail}"}</>)

             read_only(b) =
               do Ace.read_only(ace_head, b)
               do Ace.read_only(ace_body, b)
               void

             preview(f) =
               fail() = preview_template({
                  hsource = Ace.get_content(ace_head)
                  bsource = Ace.get_content(ace_body)
               })

               rec val timer = Scheduler.make_timer(1000, -> Session.send(sess,void))
               and val sess = Session.make(Date.now(),(last_date,_ -> now= Date.now()
                                                        do Log.info("d","preview update")
                                                        do
                                                          if Date.compare(Date.advance(last_date,Duration.s(2)),Date.now())=={lt}
                                                          then
                                                            do Log.info("d","preview timer stop")
                                                            _ = fail()
                                                            timer.stop()
                                                          else Log.info("d","preview update")
                                                        {set=now}
                                                         ))
               do Log.info("d","preview first start timer")
               do Ace.add_event_listener(ace_body, {change}, -> do timer.stop() timer.start())
               do Ace.add_event_listener(ace_head, {change}, -> do timer.stop() timer.start())
               match fail() with
               | {none} -> on_ok_preview(f)
               | {some=fail} -> do_report(<>{"{fail}"}</>)

            })
          )
          do Dom.transform([#{buffer_mime_id} <- <>Mimetype: text/html</>])
          void

        and build(rev : option(int)) =
          do Dom.remove_content(Dom.select_id(id))
          /* Create view */
          html =
            <div id={editor_id} class="admin_editor_content" />
            <div class="admin_editor_infos">
              <div id={reporting_id}/>
              <div id={command_id} />
              <div id={published_id} />
              <div id={buffer_mime_id} />
            </div>
          _ = Dom.put_at_end(#{id}, Dom.of_xhtml(html))
          do build_reporting()
          do build_buffers(rev)
          do build_pub_version(rev)
          void

        build(none)


    /**
     * Create a buffer for the given [file].
     */
    @private file_buffer(access:Page.full_access, opened, file) =
      id = buffer_file_id(file)
      class = if opened then "on" else "off"
      <div class="{class} admin_editor" id="{id}"
       onready={_ -> do add_tab(file, file)
                     _ = build_buffer(access, file, id) void}>
      </div>

    /**
     * Create and insert a buffer for given [file] on dom.
     */
    @client insert_buffer(access:Page.full_access, opened, file) =
      edito = Dom.select_id("admin_editor_container")
      buffer = Dom.of_xhtml(file_buffer(access, opened, file))
      _ = Dom.put_at_end(edito, buffer)
      void

    /**
     * This module provides fun action for admin interface.
     */
    @client @private Action = {{

      /**
       * Switch all "on" classes to "off" classes
       */
      @private all_off() =
        dom_on = Dom.select_class("on")
        do Dom.add_class(dom_on, "off")
        do Dom.remove_class(dom_on, "on")
        void

      expand_file(file_uri) =
        match file_uri
        {none} -> void
        {some=uri} ->
          match uri
          ~{fragment is_directory is_from_root path query} ->
            path = List.take(List.length(path)-1, path)
            _ = List.fold(
              e, acc ->
                file = Uri.to_string({~fragment ~is_directory ~is_from_root path=List.rev([e|acc]) ~query})
                fid = navigator_file_id(file)
                li_id = WHList.item_id(admin_files_id, fid)
                do if Dom.has_class(#{li_id}, "toggled") then
                  do toggle_file_sons(file, false)
                  void
                else void
                [e|acc]
              , path, [])
            void
          _ -> void

      /**
       * Open file
       */
      open_file(access:Page.full_access, file, pub) =
        do Log.info("[open_file]", "{file}")
        do all_off()
        file_uri = Uri.of_string(file)
        do file_line_insert(access, true, file_uri, pub, false, false)
        id = buffer_file_id(file)
        buf = Dom.select_id(id)
        fid = navigator_file_id(file)
        do match Dom.get_property(Dom.select_id(fid), "tab")
        {some=num} ->
          match Parser.int(num)
          {some=tab_num} ->
            WTabs.select_tab(tabs_config, tabs_file_id, tab_num, WTabs.no_tab(), false)
          {none} -> void
          end
        {none} -> void
        do if Dom.is_empty(buf) then
          insert_buffer(access, true, file)
        else
          do Dom.add_class(buf, "on")
          do Dom.remove_class(buf, "off")
          void
        // do file_line_set_edit(file, true)
        do expand_file(file_uri)
        do Dom.clear_value(#admin_new_file)
        void

      /**
       * Create a new file.
       */
      new_file(access:Page.full_access) : FunAction.t = event ->
        /* Select file to open */
        file = Dom.get_value(#admin_new_file)
        special = Dom.is_checked(#special_admin_new_file)
        file = make_absolute(file, special)
        file_uri = Uri.of_string(file)
        do Log.info("[new_file]", "New File {file} Uri {file_uri}")
        do file_line_insert(access, true, file_uri, none, false, false)
        do open_file(access, file, none)
        void

      /**
       * Remove a file
       */
      remove_file(access:Page.full_access, file) : FunAction.t = _event ->
        do access.access.remove(file)
        do access.notify.send({remove = file})
        key = navigator_file_id(file)
        fid = navigator_file_id(file)
        do match Dom.get_property(Dom.select_id(fid), "tab")
        {some=num} ->
          match Parser.int(num)
          {some=tab_num} ->
            WTabs.remove_tab(tabs_config, tabs_file_id, tab_num, {WTabs.no_tab() with custom_data=some(file)})
          {none} -> void
          end
        {none} -> void
        do match WHList.remove_item(file_config, admin_files_id, key, true) with
        | ~{some} -> Log.info("[remove_file]", "Remove OK @{some}")
        | {none} -> void
        void

      send_message(access:Page.full_access) : FunAction.t = _event ->
        input = Dom.select_id("admin_notifications_action_msg")
        talk = Dom.get_value(input)
        do access.notify.send(~{talk})
        Dom.set_value(input, "")

      search_dead_links(access:Page.full_access) : FunAction.t = _event ->
        do all_off()
        dead_links = fetch_dead_links(access)
        buf = Dom.select_id("admin_buffer_dead_links")
        edito = Dom.select_id("admin_editor_container")
        buffer = Dom.of_xhtml(
          <div id=#admin_buffer_dead_links class="on" >
            <ul>
              {StringMap.fold(key, val, acc ->
                <>{acc}
                  <li>{key} : {List.to_string_using("","",", ", val)}</li>
                </>
              , dead_links
              , <></>)}
            </ul>
          </div>
        )
        if Dom.is_empty(buf) then
          _ = Dom.put_at_end(edito, buffer)
          void
        else
          do Dom.add_class(buf, "on")
          do Dom.remove_class(buf, "off")
          void

    }}

    get_filename_mime() =
      filename = Dom.get_value(#admin_new_file)
      special = Dom.is_checked(#special_admin_new_file)
      (make_absolute(filename, special),
       Dom.get_value(#upload_mime_type))

    /* We consider a file, a resource that has a dot in its path,
       and is only at the root of the tree

       @TODO: to be improved, with handling of sub folders,
              currently, only first level is well ordered */
    is_file(file) =
      file_uri = Uri.of_string(file)
      Option.is_some(String.index(".", file)) &&
      match file_uri
      {none} -> false
      {some={fragment=_ is_directory=_ is_from_root=_ ~path query=_}} ->
        List.length(path) == 1

    /* Filters the files from the page list */
    filter_files(page_list) =
      List.filter((file, _pub, _preview) -> is_file(file), page_list)

    /* Filters the directories from the page list */
    filter_dirs(page_list) =
      List.filter((file, _pub, _preview) -> not(is_file(file)), page_list)

    /* Build the tree view */
    @client @private build_tree(access:Page.full_access)(_:Dom.event) =
      do Dom.transform([#admin_files_navigator <- WHList.html(file_config, admin_files_id, [])])
      page_list = List.unique_list_of(access.access.list())
      dirs = filter_dirs(page_list)
      files = filter_files(page_list)
      reordered_page_list = dirs ++ files
      do List.iter(
        (file, pub, preview) ->
          file_uri = Uri.of_string(file)
          file_line_insert(
            access, false, file_uri,
            (if pub.rev==0 then none else some(pub.rev)),
            preview,
            true
          )
        , reordered_page_list
      )
      access.notify.subscribe(
        | {event={publish=(file,rev)} by=_} ->
          file_line_set_publish(file,some(rev))
        | _ -> void
      )

    @client
    show_actions() =
      do Dom.hide(#admin_add_file)
      do Dom.hide(#admin_upload_file)
      do Dom.hide(#admin_refine_upload)
      do Dom.show(#admin_actions)
      void

    @server
    back_button =
      <span>
        <button type="button" onclick={ _ -> show_actions()}>&lt;</button>
      </span>

    @server
    validate_upload(access, file_data, file) =
      mime = file_data.mime ? "application/octet-stream"
      path = Dom.get_value(#admin_filepath)
      path = if path=="" then file.filename else path
      path = make_absolute(path, false)
      do Log.notice("PageUploader", "Uploading of {file.filename} ({mime}) was done")
      _rev = access.access.save(path, {binary=file.content ~mime}, none)
      do Action.open_file(access, path, none)
      void

    @server
    choose_filepath(access, file_data, file) =
      valid() =
        do validate_upload(access, file_data, file)
        do show_actions()
        void
      <>
        {back_button}
        <label for="admin_filepath">Path:</label>
        <input id="admin_filepath" name="upload_filepath" type="text" value="/{file.filename}" onnewline={_ -> valid()}/>
        <button type="button" id="validate_filepath" onclick={_ -> valid()}>Save</button>
      </>

    @server
    choose_mime(access, file_data, file) =
      next() =
        mime = Dom.get_value(#admin_mime_type)
        do Dom.transform([#admin_refine_upload <- choose_filepath(access, {file_data with mime=some(mime)}, file)])
        void
      <>
        {back_button}
        <label for="admin_mime_type">Mime-type:</label>
        <input id="admin_mime_type" name="upload_mime_type" type="text" value="{file.mimetype}" onnewline={_ -> next()}/>
        <button type="button" id="validate_mime_type" onclick={_ -> next()}>Next</button>
      </>

    @server
    perform_result(access, file_data, result) =
      match Map.get("upload_file_content", result.uploaded_files)
      | {none} -> Log.warning("PageUploader", "No file to perform")
      | {some = file} ->
        do Dom.transform([#admin_refine_upload <- choose_mime(access, file_data, file)])
        do Dom.hide(#admin_upload_file)
        do Dom.show(#admin_refine_upload)
        void

    @server
    empty_file_data =
      { mime = none
      ; content = none
      }

    @server
    config(access, form_body) = { Upload.default_config() with
      ~form_body
      process=perform_result(access, empty_file_data, _)
    }

    /**
     * Build the xhtml administration interface.
     */
    build(access:Page.full_access, url) =
      /* Add default page if url does not already exists on page map */
      /* Build admin xhtml body page */
      <div id={admin_files_id}>
        <!--<h2>Files explorer</h2>-->
        <div id="{admin_files_id}_navigator" onready={build_tree(access)}></div>
      </div>
      <div id="admin_buttons">
        { insert_add_file() =
            html =
              <>
              {back_button}
              <label for="admin_new_file">Path:</label>
              <input id="admin_new_file" name="upload_file_name" type="text" onnewline={Action.new_file(access)}/>
              <label for="special_admin_new_file">Don't force absolute:</label>
              <input id="special_admin_new_file" type="checkbox"/>
              <button type="button" onclick={Action.new_file(access)}>Open it</button>
              </>
            do Dom.transform([#admin_add_file <- html])
            do Dom.hide(#admin_actions)
            do Dom.hide(#admin_upload_file)
            do Dom.hide(#admin_refine_upload)
            do Dom.show(#admin_add_file)
            void
          insert_upload_file() =
            html =
              <>
              {back_button}
              <input type="file" name="upload_file_content"/>
              <button type="submit">Upload</button>
              </>
            do Dom.transform([#admin_upload_file <- html])
            do Dom.hide(#admin_actions)
            do Dom.hide(#admin_add_file)
            do Dom.hide(#admin_refine_upload)
            do Dom.show(#admin_upload_file)
            void
          body_form =
            <div id="admin_actions">
              <span>
                <button type="button" onclick={ _ ->
                  _ = insert_add_file()
                  Log.info("[action]", "add file")
                }>Open</button>
              </span>
              <span>
                <button type="button" onclick={ _ ->
                  _ = insert_upload_file()
                  Log.info("[action]", "upload file")
                }>Upload</button>
              </span>
              <span>
                <button type="button" onclick={Action.search_dead_links(access)}>Search for dead links</button>
              </span>
            </div>
            <div id="admin_upload_file" style="display:none"/>
          up = Upload.html(config(access, body_form))
          <>
            {up}
            <div id=#file_more>
              <div id="admin_add_file" style="display:none"/>
              <div id="admin_refine_upload" style="display:none"/>
            </div>
          </>
        }
      </div>

      <div id="admin_notifications">
        <div id="admin_notifications_box" onready={_ ->
          handler(~{event by}) =
            message = match event
              | {connect} -> "{by} is now connected"
              | ~{save} -> "{by} save {save}"
              | ~{open} -> "{by} open {open}"
              | ~{lock} -> "{by} lock {lock}"
              | ~{release} -> "{by} release {release}"
              | ~{remove} -> "{by} remove {remove}"
              | ~{talk} -> "{by} says {talk}"
              | ~{publish} -> "{by} publish {publish.f1} rev {publish.f2}"
            xhtml = <div>{message}</div>
            dom = Dom.select_id("admin_notifications_box")
            _ = Dom.put_at_end(dom, Dom.of_xhtml(xhtml))
            do Dom.scroll_to_bottom(dom)
            void
          _ = access.notify.subscribe(handler)
          _ = access.notify.send({connect})
          void
        }>
        </div>
        <div id="admin_notifications_action">
          <input type="text" onnewline={Action.send_message(access)} id="admin_notifications_action_msg"/>
          <button onclick={Action.send_message(access)}>Send a message</button>
        </div>
      </div>

      <div id="admin_editor_container">
        {tabs_html()}
        {file_buffer(access, true, url)}
      </div>

  }}

  @private build_resource(engine, content, modified_on) =
    add_web_cache(r) =
      Option.switch(modified_on -> Resource.cache_control(r, ~{modified_on}), r, modified_on)
    match content with
    | ~{image}             -> {resource = add_web_cache(Resource.image(image))}
    | ~{css}               -> {resource = add_web_cache(Resource.build_css(css))}
    | ~{source mime}       -> {resource = add_web_cache(Resource.source(source, mime))}
    | ~{binary mime}       -> {resource = add_web_cache(Resource.source(binary, mime))}
    | ~{hcontent bcontent} ->
      {embedded = {
         head = Template.to_xhtml(engine, Template.parse(engine, hcontent))
         body = Template.to_xhtml(engine, Template.parse(engine, bcontent))
      } } : Page.t

  /**
   * Provides an interface which allows to create and modify pages.
   * This iterface is composed :
   *   1 - A file viewer
   *   2 - A code editor
   *   3 - An action zone
   * This admin interface open by default an editor for [url] file.
   */
  make(config:Page.config('a, 'b)) : Page.manager =
    srvacc = ServerAccess(config)
    access = srvacc.access("server")
    admin(url, user) =
      AdminGui.build(srvacc.full(user), url)
    source(url) = Option.bind(
      ((page:Page.stored,_) -> match page.content
        | ~{css} -> some(css)
        | ~{source ...} -> some(source)
        | ~{bcontent ...} -> some(bcontent)
        | _ -> none),
        access.get(url))
    resource_with_env(url, env) =
      engine = config.engine(env)
      res = match get_preview(url) with
        | {some=r} -> some((r, Date.now()))
        | {none} -> Option.map((x,_)->(x.content, x.date) ,access.get(url))
      match res with
      | {none} -> {resource =
          match access.get("404.xmlt")
          | {none} -> Resource.full_page("Not found",<h1>404 - Not found</h1>, <></>, {found}, [])
          | {some=(r,_)} ->
            match build_resource(engine, r.content, {some = r.date})
            | {embedded = ~{body head}} -> Resource.full_page("", body, head, {found}, [])
            | x -> to_resource(x)
        }
      | {some=(resource, date)} ->
        build_resource(engine, resource, {some = date})
    resource(url) =
      env = { current_url = url }
      resource_with_env(url, env)
    try_resource(url) =
      engine = config.engine({ current_url = url })
      Option.map(((resource,_) -> build_resource(engine, resource.content, {some = resource.date})),
                 access.get(url))

    ~{admin resource resource_with_env try_resource source}

  to_resource:Page.t -> resource =
    | ~{resource} -> resource
    | ~{embedded} -> Resource.full_page("", <>{embedded.body}{WNotification.html(WNotification.default_config, "notify")}</>, embedded.head,
                       {success}, [])

  empty: Page.stored =
    {author="server" content={source = "" mime = "text/plain" } date=Date.now() parent=-1}

  not_published: Page.published =
    {author="server" rev=-1 date=Date.now()}

  rev_of_published(p : Page.published) : int = p.rev
}}
