%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_plugin).
-include("rabbit.hrl").

-export([start/0, stop/0]).

-define(FORCE_OPT, "-f").

-record(plugin, {name,          %% atom()
                 version,       %% string()
                 description,   %% string()
                 dependencies,  %% [{atom(), string()}]
                 location}).    %% string()

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start/0 :: () -> no_return()).
-spec(stop/0 :: () -> 'ok').

-endif.

%%----------------------------------------------------------------------------

start() ->
    {ok, [[PluginsDir|_]|_]} = init:get_argument(plugins_dir),
    {ok, [[PluginsDistDir|_]|_]} = init:get_argument(plugins_dist_dir),
    {[Command0 | Args], Opts} =
        case rabbit_misc:get_options([{flag, ?FORCE_OPT}],
                                     init:get_plain_arguments()) of
            {[], _Opts}    -> usage();
            CmdArgsAndOpts -> CmdArgsAndOpts
        end,
    Command = list_to_atom(Command0),

    case catch action(Command, Args, Opts, PluginsDir, PluginsDistDir) of
        ok ->
            rabbit_misc:quit(0);
        {'EXIT', {function_clause, [{?MODULE, action, _} | _]}} ->
            print_error("invalid command '~s'",
                        [string:join([atom_to_list(Command) | Args], " ")]),
            usage();
        {error, Reason} ->
            print_error("~p", [Reason]),
            rabbit_misc:quit(2);
        Other ->
            print_error("~p", [Other]),
            rabbit_misc:quit(2)
    end.

stop() ->
    ok.

print_error(Format, Args) ->
    rabbit_misc:format_stderr("Error: " ++ Format ++ "~n", Args).

usage() ->
    io:format("Insert USAGE here.~n"),
    rabbit_misc:quit(1).

%%----------------------------------------------------------------------------

action(list, [], _Opts, PluginsDir, PluginsDistDir) ->
    format_plugins(find_plugins(PluginsDir), find_plugins(PluginsDistDir));

action(enable, ToEnable0, _Opts, PluginsDir, PluginsDistDir) ->
    AllPlugins = find_plugins(PluginsDistDir),
    ToEnable = [list_to_atom(Name) || Name <- ToEnable0],
    ToEnablePlugins = lookup_plugins(ToEnable, AllPlugins),
    Missing = ToEnable -- plugin_names(ToEnablePlugins),
    case Missing of
        [] -> ok;
        _  -> io:format("Warning: the following plugins could not be found: ~p~n",
                        [Missing])
    end,
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun (App, _Deps) -> [{App, App}] end,
                fun (App,  Deps) -> [{App, Dep} || Dep <- Deps] end,
                [{Name, Deps}
                 || #plugin{name = Name, dependencies = Deps} <- AllPlugins]),
    EnableOrder = digraph_utils:reachable(plugin_names(ToEnablePlugins), G),
    true = digraph:delete(G),
    io:format("Marked for enabling: ~p~n", [EnableOrder]),
    ok = lists:foldl(
           fun (#plugin{name = Name, version = Version, location = Path}, ok) ->
                   io:format("Enabling ~w-~s~n", [Name, Version]),
                   case file:copy(Path, filename:join(PluginsDir,
                                                      filename:basename(Path))) of
                       {ok, _Bytes}    -> ok;
                       {error, Reason} -> io:format("Error enabling ~p (~p)~n",
                                                    [Name, Reason]),
                                          rabbit_misc:quit(2)
                   end
           end, ok, lookup_plugins(EnableOrder, AllPlugins)),
    InstalledPlugins = lookup_plugins(read_enabled_plugins(), AllPlugins),
    update_enabled_plugins(plugin_names(merge_plugin_lists(InstalledPlugins,
                                                           ToEnablePlugins))).

%%----------------------------------------------------------------------------

find_plugins(PluginsDistDir) ->
    EZs = filelib:wildcard("*.ez", PluginsDistDir),
    {Plugins, Problems} =
        lists:foldl(fun ({error, EZ, Reason}, {Plugins1, Problems1}) ->
                            {Plugins1, [{EZ, Reason} | Problems1]};
                        (Plugin = #plugin{}, {Plugins1, Problems1}) ->
                            {[Plugin|Plugins1], Problems1}
                    end, {[], []},
                    [get_plugin_info(filename:join([PluginsDistDir, EZ]))
                     || EZ <- EZs]),
    case Problems of
        [] -> ok;
        _  -> io:format("Warning: Problem reading some plugins: ~p~n", [Problems])
    end,
    Plugins.

get_plugin_info(EZ) ->
    case read_app_file(EZ) of
        {application, Name, Props} ->
            Version = proplists:get_value(vsn, Props, "0"),
            Description = proplists:get_value(description, Props, ""),
            Dependencies =
                filter_applications(proplists:get_value(applications, Props, [])),
            #plugin{name = Name, version = Version, description = Description,
                    dependencies = Dependencies, location = EZ};
        {error, Reason} ->
            {error, EZ, Reason}
    end.

%% Read the .app file from an ez.
read_app_file(EZ) ->
    case zip:list_dir(EZ) of
        {ok, [_|ZippedFiles]} ->
            case find_app_files(ZippedFiles) of
                [AppPath|_] ->
                    {ok, [{AppPath, AppFile}]} =
                        zip:extract(EZ, [{file_list, [AppPath]}, memory]),
                    parse_binary(AppFile);
                [] ->
                    {error, no_app_file}
            end;
        {error, Reason} ->
            {error, {invalid_ez, Reason}}
    end.

%% Return the path of the .app files in ebin/.
find_app_files(ZippedFiles) ->
    {ok, RE} = re:compile("^.*/ebin/.*.app$"),
    [Path || {zip_file, Path, _, _, _, _} <- ZippedFiles,
             re:run(Path, RE, [{capture, none}]) =:= match].

%% Parse a binary into a term.
parse_binary(Bin) ->
    try
        {ok, Ts, _} = erl_scan:string(binary:bin_to_list(Bin)),
        {ok, Term} = erl_parse:parse_term(Ts),
        Term
    catch
        Err -> {error, {invalid_app, Err}}
    end.

%% Pretty print a list of plugins.
format_plugins(Enabled, Provided) ->
    EnabledSet = sets:from_list([Name || #plugin{name = Name} <- Enabled]),
    [case sets:is_element(Name, EnabledSet) of
         false -> format_available_plugin(Plugin);
         true  -> format_enabled_plugin(Plugin)
     end
     || Plugin = #plugin{name = Name} <- usort_plugins(Enabled ++ Provided)],
    ok.

format_available_plugin(#plugin{name = Name, version = Version,
                                description = Description}) ->
    io:format("[N] ~w-~s: ~s~n", [Name, Version, Description]).

format_enabled_plugin(#plugin{name = Name, version = Version,
                              description = Description}) ->
    io:format("[E] ~w-~s: ~s~n", [Name, Version, Description]).

usort_plugins(Plugins) ->
    lists:usort(fun plugins_cmp/2, Plugins).

%% Merge two plugin lists.  In case of duplicates, only keep highest
%% version.
merge_plugin_lists(Ps1, Ps2) ->
    filter_duplicates(usort_plugins(Ps1 ++ Ps2)).

filter_duplicates([P1 = #plugin{name = N, version = V1},
                   P2 = #plugin{name = N, version = V2} | Ps]) ->
    if V1 < V2 -> [P2 | filter_duplicates(Ps)];
       true    -> [P1 | filter_duplicates(Ps)]
    end;
filter_duplicates([P | Ps]) ->
    [P | filter_duplicates(Ps)];
filter_duplicates(Ps) ->
    Ps.

plugins_cmp(#plugin{name = N1, version = V1}, #plugin{name = N2, version = V2}) ->
    {N1, V1} =< {N2, V2}.

%% Filter applications that can be loaded *right now*.
filter_applications(Applications) ->
    [Application || Application <- Applications,
                    case application:load(Application) of
                        {error, {already_loaded, _}} -> false;
                        ok -> application:unload(Application),
                              false;
                        _  -> true
                    end].

%% Return the names of the given plugins.
plugin_names(Plugins) ->
    [Name || #plugin{name = Name} <- Plugins].

%% Find plugins by name in a list of plugins.
lookup_plugins(Names, AllPlugins) ->
    [P || P = #plugin{name = Name} <- AllPlugins, lists:member(Name, Names)].

%% Read the enabled plugin names from disk.
read_enabled_plugins() ->
    [].

%% Update the enabled plugin names on disk.
update_enabled_plugins(NewPlugins) ->
    io:format("Adding ~p to enabled plugins~n", [NewPlugins]).
