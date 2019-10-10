-module(bpe).
-author('Maxim Sokhatsky').
-include("bpe.hrl").
-include_lib("kvs/include/cursors.hrl").
-include("api.hrl").
-export([head/1,trace/4]).
-compile(export_all).
-define(TIMEOUT, application:get_env(bpe,timeout,60000)).

load(Id) -> load(Id, []).
load(Id, Def) ->
    case kvs:get("/bpe/proc",Id) of
         {error,_} -> Def;
         {ok,Proc} -> {_,T} = current_task(Id),
                      Proc#process{task=T} end.

cleanup(P) ->
  [ kvs:delete("/bpe/hist",Id) || #hist{id=Id} <- bpe:hist(P) ],
    kvs:delete(writer,"/bpe/hist/" ++ P),
  [ kvs:delete("/bpe/flow",Id) || #sched{id=Id} <- sched(P) ],
    kvs:delete(writer, "/bpe/flow/" ++ P),
    kvs:delete("/bpe/proc",P).

current_task(Id) ->
    case bpe:head(Id) of
         [] -> {empty,'Created'};
         #hist{id={step,H,_},task=T} -> {H,T} end. %% H - ProcId

trace(Proc,Name,Time,Task) ->
    Key = "/bpe/hist/" ++ Proc#process.id,
    Writer = kvs:writer(Key),
    kvs:append(Proc,"/bpe/proc"),
    kvs:append(#hist{ id = {step,Writer#writer.count,Proc#process.id},
                    name = Name,
                    time = #ts{ time = Time},
                    docs = Proc#process.docs,
                    task = Task}, Key).

add_sched(Proc,Pointer,State) ->
    Key = "/bpe/flow/" ++ Proc#process.id,
    Writer = kvs:writer(Key),
    kvs:append(#sched{ id = {step,Writer#writer.count,Proc#process.id},
                  pointer = Pointer,
                    state = State}, Key).

start(Proc0, Options) ->
    Id   = case Proc0#process.id of [] -> kvs:seq([],[]); X -> X end,
    {Hist,Task} = current_task(Id),
    Pid  = proplists:get_value(notification,Options,undefined),
    Proc = Proc0#process{id=Id,
           task= Task,
           options = Options,
           notifications = Pid,
           started= #ts{ time = calendar:local_time() } },

    case Hist of empty -> trace(Proc,[],calendar:local_time(),Task),
                          add_sched(Proc,1,[first_flow(Proc)]);
                 _ -> skip end,

    Restart = transient,
    Shutdown = ?TIMEOUT,
    ChildSpec = { Id,
                  {bpe_proc, start_link, [Proc]},
                  Restart, Shutdown, worker, [bpe_proc] },

    case supervisor:start_child(bpe_otp,ChildSpec) of
         {ok,_}    -> {ok,Proc#process.id};
         {ok,_,_}  -> {ok,Proc#process.id};
         {error,_} -> {error,Proc#process.id} end.

pid(Id) -> bpe:cache({process,Id}).

proc(ProcId)              -> gen_server:call(pid(ProcId),{get},            ?TIMEOUT).
complete(ProcId)          -> gen_server:call(pid(ProcId),{complete},       ?TIMEOUT).
next(ProcId)              -> gen_server:call(pid(ProcId),{next},           ?TIMEOUT).
complete(ProcId,Stage)    -> gen_server:call(pid(ProcId),{complete,Stage}, ?TIMEOUT).
amend(ProcId,Form)        -> gen_server:call(pid(ProcId),{amend,Form},     ?TIMEOUT).
discard(ProcId,Form)      -> gen_server:call(pid(ProcId),{discard,Form},   ?TIMEOUT).
modify(ProcId,Form,Arg)   -> gen_server:call(pid(ProcId),{modify,Form,Arg},?TIMEOUT).
event(ProcId,Event)       -> gen_server:call(pid(ProcId),{event,Event},    ?TIMEOUT).

first_flow(#process{beginEvent = BeginEvent, flows = Flows}) ->
  io:format("Flows=~p~nBegin=~p~n", [Flows, BeginEvent]),
  (lists:keyfind(BeginEvent, #sequenceFlow.source, Flows))#sequenceFlow.name.

head(ProcId) ->
  case kvs:get(writer,"/bpe/hist/" ++ ProcId) of
       {ok, #writer{count = C}} -> case kvs:get("/bpe/hist/" ++ ProcId,{step,C - 1,ProcId}) of
       {ok, X} -> X; _ -> [] end; _ -> [] end.

sched(#step{proc = ProcId}=Step) ->
  case kvs:get("/bpe/flow/" ++ ProcId,Step) of {ok, X} -> X; _ -> [] end;

sched(ProcId) -> kvs:feed("/bpe/flow/" ++ ProcId).

sched_head(ProcId) ->
  case kvs:get(writer,"/bpe/flow/" ++ ProcId) of
       {ok, #writer{count = C}} -> case kvs:get("/bpe/flow/" ++ ProcId,{step,C - 1,ProcId}) of
       {ok, X} -> X; _ -> [] end; _ -> [] end.

hist(ProcId)   -> kvs:feed("/bpe/hist/" ++ ProcId).
hist(ProcId,N) -> case application:get_env(kvs,dba,kvs_mnesia) of
                       kvs_mnesia -> case kvs:get(hist,{N,ProcId}) of
                                          {ok,Res} -> Res;
                                          {error,_Reason} -> [] end;
                       kvs_rocks  -> case kvs:get("/bpe/hist/" ++ ProcId,{step,N,ProcId}) of
                                          {ok,Res} -> Res;
                                          {error,_Reason} -> [] end end .

step(Proc,Name) ->
    case [ Task || Task <- tasks(Proc), element(#task.name,Task) == Name] of
         [T] -> T;
         [] -> #task{};
         E -> E end.

docs  (Proc) -> Proc#process.docs.
tasks (Proc) -> Proc#process.tasks.
events(Proc) -> Proc#process.events.
doc (R,Proc) -> {X,_} = bpe_env:find(env,Proc,R), case X of [A] -> A; _ -> X end.

% Emulate Event-Condition-Action Systems

'ECA'(Proc,Document,Cond) -> 'ECA'(Proc,Document,Cond,fun(_,_)-> ok end).
'ECA'(Proc,Document,Cond,Action) ->
    case Cond(Document,Proc) of
         true -> Action(Document,Proc), {reply,Proc};
         {false,Message} -> {{reply,Message},Proc#process.task,Proc};
         ErrorList -> io:format("ECA/4 failed: ~tp~n",[ErrorList]),
                      {{reply,ErrorList},Proc#process.task,Proc} end.

cache(Key, undefined) -> ets:delete(processes,Key);
cache(Key, Value) -> ets:insert(processes,{Key,till(calendar:local_time(), ttl()),Value}), Value.
cache(Key, Value, Till) -> ets:insert(processes,{Key,Till,Value}), Value.
cache(Key) ->
    Res = ets:lookup(processes,Key),
    Val = case Res of [] -> undefined; [Value] -> Value; Values -> Values end,
    case Val of undefined -> undefined;
                {_,infinity,X} -> X;
                {_,Expire,X} -> case Expire < calendar:local_time() of
                                  true ->  ets:delete(processes,Key), undefined;
                                  false -> X end end.

ttl() -> application:get_env(bpe,ttl,60*15).

till(Now,TTL) ->
    case is_atom(TTL) of
        true -> TTL;
        false -> calendar:gregorian_seconds_to_datetime(
                    calendar:datetime_to_gregorian_seconds(Now) + TTL)
    end.

reload(Module) ->
    {Module, Binary, Filename} = code:get_object_code(Module),
    case code:load_binary(Module, Filename, Binary) of
        {module, Module} ->
            {reloaded, Module};
        {error, Reason} ->
            {load_error, Module, Reason}
    end.

send(Pool, Message) -> syn:publish(term_to_binary(Pool),Message).
reg(Pool) -> reg(Pool,undefined).
reg(Pool, Value) ->
  case get({pool,Pool}) of
    undefined -> syn:register(term_to_binary(Pool),self(),Value),
                 syn:join(term_to_binary(Pool),self()),
                 erlang:put({pool,Pool},Pool);
     _Defined -> skip end.

unreg(Pool) ->
  case get({pool,Pool}) of
    undefined -> skip;
     _Defined -> syn:leave(Pool, self()),
                 erlang:erase({pool,Pool}) end.

%%%%

%% bpe_env:find doc 
%% bpe:head(Proc#process.id) - last hist
processFlow(#process{}=Proc) ->
    #sched{id=ScedId, pointer=Pointer, state=Threads} = sched_head(Proc#process.id),
    %%TODO -> exit if length(Threads) == 0
    X = lists:nth(Pointer, Threads),
    Flow = lists:keyfind(lists:nth(Pointer, Threads), #sequenceFlow.name, Proc#process.flows),
    io:format("flow: ~p~nX: ~p~nFlows: ~p~n",[Flow, X, Proc#process.flows]),
    Vertex = lists:keyfind(Flow#sequenceFlow.target, #gateway.name, tasks(Proc)),
    %io:write("Vertex=~w\n",[Vertex]),
    %%%%%%%%%
    Required = element(#gateway.inputs, Vertex) -- [Flow], %Current sequenceFlow is not stored yet
    io:format("Required=~w\nVertex=~w\n",[Required,Vertex]),
    Check = check_required2(ScedId, map_required_fun(Vertex),Required),
    Inserted = case Check of true -> element(#gateway.outputs, Vertex); false -> [] end,
    %%%%%%%%%
    NewThreads = lists:sublist(Threads, Pointer-1) ++ Inserted ++ lists:nthtail(Pointer, Threads),
    NewPointer = if Pointer == length(Threads) -> 1; true -> Pointer + length(Inserted) end,
    add_sched(Proc, NewPointer, NewThreads),
    %% \/adapters to old code\/
    #sequenceFlow{name=Next, source=Src,target=Dst} = Flow,
    %% \/Old code \/
    %%This will work only if there are some behavior((Source=Module):action) defined for events
    Source = step(Proc,Src), %vertex From
    Target = step(Proc,Dst), %vertex To is the Vertex
    Resp = {Status,{Reason,_Reply},State} = bpe_task:task_action(element(#task.module, Vertex),Src,Dst,Proc),
    trace(State,[],calendar:local_time(),Flow),
    bpe_proc:debug(State,Next,Src,Dst,Status,Reason),
    Resp.

%TODO: get_Inserted(Vertex,Flow) -> Inserted

map_required_fun(#gateway{type=parallel})->
    fun(Required, Flow) -> Required -- [Flow] end;
map_required_fun(#gateway{type=inclusive})-> %%all
    fun(Required, Flow) -> Required -- [Flow] end;
map_required_fun(#gateway{type=exclusive}) -> %%any
    fun(Required, Flow) -> case lists:member(Flow, Required) of true->[];false->Required end end;
map_required_fun(_) -> fun(_,_) -> [] end.

check_required2(_,_,[]) -> true;
check_required2(#step{id=-1},_,_) -> false;
check_required2(#step{id=Id}=SchedId,MapFun,Required) ->
  io:format("check_required2:~w\n",[{SchedId,MapFun,Required}]),
    NewRequired = MapFun(Required, flow(sched(SchedId))),
    check_required2(SchedId#step{id=Id-1}, MapFun, NewRequired).

flow(#sched{state=Flows, pointer=N}) -> lists:nth(N, Flows).
%%%%
selectFlow(Proc,Name) ->
    case kvs:get("/bpe/flow/"++Proc#process.id,Name) of
         {ok,#sequenceFlow{name=Name}=Flow} -> Flow;
         {error,_} -> #sequenceFlow{name=Name} end.

completeFlow(Proc) ->
    Next = Proc#process.task,
    #sequenceFlow{name=Next,source=Src,target=Dst} = Flow = selectFlow(Proc,Next),
    Source = step(Proc,Src),
    Target = step(Proc,Dst),
    Resp = {Status,{Reason,_Reply},State} = bpe_task:task_action(Source,Src,Dst,Proc),
    %%
    bpe_proc:prepareNext(Target,State),
    bpe:trace(State,[],calendar:local_time(),Flow),
    bpe_proc:debug(State,Next,Src,Dst,Status,Reason),
    Resp.
