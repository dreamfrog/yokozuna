%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(yz_solr).
-compile(export_all).
-include("yokozuna.hrl").

-define(CORE_ALIASES, [{index_dir, instanceDir},
                       {cfg_file, config},
                       {schema_file, schema},
                       {delete_instance, deleteInstanceDir}]).
-define(FIELD_ALIASES, [{continuation, continue},
                        {limit,n}]).
-define(DEFAULT_URL, "http://localhost:8983/solr").
-define(DEFAULT_VCLOCK_N, 1000).
-define(QUERY(Str), {struct, [{'query', Str}]}).

%% @doc This module provides the interface for making calls to Solr.
%%      All interaction with Solr should go through this API.

%%%===================================================================
%%% API
%%%===================================================================

-spec build_partition_delete_query(ordset(lp())) -> term().
build_partition_delete_query(LPartitions) ->
    Deletes = [{delete, ?QUERY(<<?YZ_PN_FIELD_S, ":", (?INT_TO_BIN(LP))/binary>>)}
               || LP <- LPartitions],
    mochijson2:encode({struct, Deletes}).

commit(Core) ->
    BaseURL = base_url() ++ "/" ++ Core ++  "/update",
    JSON = encode_commit(),
    Params = [{commit, true}],
    Encoded = mochiweb_util:urlencode(Params),
    URL = BaseURL ++ "?" ++ Encoded,
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, post, JSON, Opts) of
        {ok, "200", _, _} -> ok;
        Err -> throw({"Failed to commit", Err})
    end.

%% @doc Perform Core related actions.
-spec core(atom(), proplists:proplist()) -> {ok, any(), any()}.
core(Action, Props) ->
    BaseURL = base_url() ++ "/admin/cores",
    Action2 = convert_action(Action),
    Params = proplists:substitute_aliases(?CORE_ALIASES,
                                          [{action, Action2}|Props]),
    Encoded = mochiweb_util:urlencode(Params),
    Opts = [{response_format, binary}],
    URL = BaseURL ++ "?" ++ Encoded,

    case ibrowse:send_req(URL, [], get, [], Opts) of
        {ok, "200", Headers, Body} ->
            {ok, Headers, Body};
        X ->
            throw({error_calling_solr, core, Action, X})
    end.

-spec cores() -> ordset(index_name()).
cores() ->
    {ok, _, Body} = yz_solr:core(status, [{wt,json}]),
    Status = yz_solr:get_path(mochijson2:decode(Body), [<<"status">>]),
    ordsets:from_list([binary_to_list(Name) || {Name, _} <- Status]).

-spec delete(string(), string()) -> ok.
delete(Core, DocID) ->
    BaseURL = base_url() ++ "/" ++ Core ++ "/update",
    JSON = encode_delete({id,DocID}),
    Params = [],
    Encoded = mochiweb_util:urlencode(Params),
    URL = BaseURL ++ "?" ++ Encoded,
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, post, JSON, Opts) of
        {ok, "200", _, _} -> ok;
        Err -> throw({"Failed to delete doc", DocID, Err})
    end.

delete_by_query(Core, JSON) ->
    BaseURL = base_url() ++ "/" ++ Core ++ "/update",
    Headers = [{content_type, "application/json"}],
    case ibrowse:send_req(BaseURL, Headers, post, JSON, []) of
        {ok, "200", _, _} -> ok;
        Err -> throw({"Failed to delete by query", JSON, Err})
    end.

%% @doc Get slice of entropy data.  Entropy data is used to build
%%      hashtrees for active anti-entropy.  This is meant to be called
%%      in an iterative fashion in order to page through the entropy
%%      data.
%%
%%  `Core' - The core to get entropy data for.
%%
%%  `Filter' - The list of constraints to filter out entropy
%%             data.
%%
%%    `before' - An ios8601 datetime, return data for docs written
%%               before and including this moment.
%%
%%    `continuation' - An opaque value used to continue where a
%%                     previous return left off.
%%
%%    `limit' - The maximum number of entries to return.
%%
%%    `partition' - Return entries for specific logical partition.
%%
%%  `ED' - An entropy data record containing list of entries and
%%         continuation value.
-spec entropy_data(string(), ed_filter()) ->
                          ED::entropy_data() | {error, term()}.
entropy_data(Core, Filter) ->
    BaseURL = base_url() ++ "/" ++ Core ++ "/entropy_data",
    Params = [{wt, json}|Filter] -- [{continuation, none}],
    Params2 = proplists:substitute_aliases(?FIELD_ALIASES, Params),
    Opts = [{response_format, binary}],
    URL = BaseURL ++ "?" ++ mochiweb_util:urlencode(Params2),
    case ibrowse:send_req(URL, [], get, [], Opts) of
        {ok, "200", _Headers, Body} ->
            R = mochijson2:decode(Body),
            More = json_get_key(<<"more">>, R),
            Continuation = get_continuation(More, R),
            Pairs = get_pairs(R),
            make_ed(More, Continuation, Pairs);
        X ->
            {error, X}
    end.

%% @doc Index the given `Docs'.
index(Core, Docs) ->
    BaseURL = base_url() ++ "/" ++ Core ++ "/update",
    JSON = prepare_json(Docs),
    Params = [],
    Encoded = mochiweb_util:urlencode(Params),
    URL = BaseURL ++ "?" ++ Encoded,
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, post, JSON, Opts) of
        {ok, "200", _, _} -> ok;
        Err -> throw({"Failed to index docs", Docs, Err})
    end.

prepare_json(Docs) ->
    Content = {struct, [{add, encode_doc(D)} || D <- Docs]},
    mochijson2:encode(Content).

%% @doc Return the set of unique partitions stored on this node.
-spec partition_list(string()) -> binary().
partition_list(Core) ->
    BaseURL = base_url() ++ "/" ++ Core ++ "/select",
    Params = [{q, "*:*"},
              {facet, "on"},
              {"facet.mincount", "1"},
              {"facet.field", ?YZ_PN_FIELD_S},
              {wt, "json"}],
    Encoded = mochiweb_util:urlencode(Params),
    URL = BaseURL ++ "?" ++ Encoded,
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, [], get, [], Opts) of
        {ok, "200", _, Resp} -> Resp;
        Err -> throw({"Failed to get partition list", URL, Err})
    end.

%% @doc Return boolean based on ping response from Solr.
-spec ping(string()) -> boolean().
ping(Core) ->
    URL = base_url() ++ "/" ++ Core ++ "/admin/ping",
    case ibrowse:send_req(URL, [], get) of
        {ok, "200", _, _} -> true;
        _ -> false
    end.

port() ->
    app_helper:get_env(?YZ_APP_NAME, solr_port, ?YZ_DEFAULT_SOLR_PORT).

jmx_port() ->
    app_helper:get_env(?YZ_APP_NAME, solr_jmx_port, undefined).

search(Core, Params, Mapping) ->
    search(Core, [], Params, Mapping).

search(Core, Headers, Params, Mapping) ->
    {Nodes, FilterPairs} = yz_cover:plan(Core),
    HostPorts = [proplists:get_value(Node, Mapping) || Node <- Nodes],
    ShardFrags = [shard_frag(Core, HostPort) || HostPort <- HostPorts],
    ShardFrags2 = string:join(ShardFrags, ","),
    FQ = build_fq(FilterPairs),
    BaseURL = base_url() ++ "/" ++ Core ++ "/select",
    Params2 = Params ++ [{fq, FQ}],
    Encoded = mochiweb_util:urlencode(Params2),
    %% NOTE: For some reason ShardFrags2 breaks urlencode so add it
    %%       manually
    URL = BaseURL ++ "?shards=" ++ ShardFrags2 ++ "&" ++ Encoded,
    Body = [],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, get, Body, Opts) of
        {ok, "200", RHeaders, Resp} -> {RHeaders, Resp};
        {ok, "404", _, _} -> throw(not_found);
        Err -> throw({"Failed to search", URL, Err})
    end.

%%%===================================================================
%%% Private
%%%===================================================================

%% @doc Get the base URL.
base_url() ->
    "http://localhost:" ++ port() ++ "/solr".

build_fq(Partitions) ->
    GroupedByNode = yz_misc:group_by(Partitions, fun group_by_node/1),
    Fields = [group_to_str(G) || G <- GroupedByNode],
    string:join(Fields, " OR ").

group_by_node({{Partition, Owner}, all}) ->
    {Owner, Partition};
group_by_node({{Partition, Owner}, FPFilter}) ->
    {Owner, {Partition, FPFilter}}.

group_to_str({Owner, Partitions}) ->
    OwnerQ = ?YZ_NODE_FIELD_S ++ ":" ++ atom_to_list(Owner),
    "(" ++ OwnerQ ++ " AND " ++ "(" ++ partitions_to_str(Partitions) ++ "))".

partitions_to_str(Partitions) ->
    F = fun({Partition, FPFilter}) ->
                PNQ = pn_str(Partition),
                FPQ = string:join(lists:map(fun fpn_str/1, FPFilter), " OR "),
                "(" ++ PNQ ++ " AND " ++ "(" ++ FPQ ++ "))";
           (Partition) ->
                pn_str(Partition)
        end,
    string:join(lists:map(F, Partitions), " OR ").

pn_str(Partition) ->
    ?YZ_PN_FIELD_S ++ ":" ++ integer_to_list(Partition).

fpn_str(FPN) ->
    ?YZ_FPN_FIELD_S ++ ":" ++ integer_to_list(FPN).

convert_action(create) -> "CREATE";
convert_action(status) -> "STATUS";
convert_action(remove) -> "UNLOAD".

encode_commit() ->
    <<"{}">>.

encode_delete({key,Key}) ->
    Query = ?YZ_RK_FIELD_S ++ ":" ++ binary_to_list(Key),
    mochijson2:encode({struct, [{delete, ?QUERY(list_to_binary(Query))}]});

encode_delete({key,Key,siblings}) ->
    Query = ?YZ_RK_FIELD_S ++ ":" ++ binary_to_list(Key) ++ " AND " ++ ?YZ_VTAG_FIELD_S ++ ":[* TO *]",
    mochijson2:encode({struct, [{delete, ?QUERY(list_to_binary(Query))}]});

encode_delete({id,Id}) ->
    mochijson2:encode({struct, [{delete, {struct, [{id, list_to_binary(Id)}]}}]}).

encode_doc({doc, Fields}) ->
    {struct, [{doc, lists:map(fun encode_field/1,Fields)}] };

encode_doc({doc, Boost, Fields}) ->
	{struct, [{doc, [{boost, Boost}], lists:map(fun encode_field/1, Fields)}]}.

% encode_field({Name,Value}) when is_binary(Value) ->
%     {Name, Value};

encode_field({Name,Value}) when is_list(Value) ->
    {Name, list_to_binary(Value)};

encode_field({Name,Value}) ->
    {Name, Value};

encode_field({Name,Value,Boost}) ->
    FieldContent = {struct, [{boost, Boost}, {value, Value}]},
    {struct, [{Name, FieldContent}]}.

%% @doc Get the continuation value if there is one.
get_continuation(false, _R) ->
    none;
get_continuation(true, R) ->
    json_get_key(<<"continuation">>, R).

get_pairs(R) ->
    Docs = json_get_key(<<"docs">>, get_response(R)),
    [to_pair(DocStruct) || DocStruct <- Docs].

to_pair({struct, [{_,Bucket},{_,Key},{_,Base64Hash}]}) ->
    {{Bucket,Key}, base64:decode(Base64Hash)}.

get_path({struct, PL}, Path) ->
    get_path(PL, Path);
get_path(PL, [Name]) ->
    case proplists:get_value(Name, PL) of
        {struct, Obj} -> Obj;
        Val -> Val
    end;
get_path(PL, [Name|Path]) ->
    get_path(proplists:get_value(Name, PL), Path).

get_response(R) ->
    json_get_key(<<"response">>, R).

%% @doc Given a "struct" created by `mochijson2:decode' get the given
%%      `Key' or throw if not found.
json_get_key(Key, {struct, PL}) ->
    case proplists:get_value(Key, PL) of
        undefined -> {error, not_found, Key, PL};
        Val -> Val
    end;
json_get_key(_Key, Term) ->
    throw({error, "json_get_key: Term not a struct", Term}).

make_ed(More, Continuation, Pairs) ->
    #entropy_data{more=More, continuation=Continuation, pairs=Pairs}.

shard_frag(Core, {Host, Port}) ->
    Host ++ ":" ++ Port ++ "/solr/" ++ Core.
