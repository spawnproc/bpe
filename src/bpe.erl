-module(bpe).
-author('Maxim Sokhatsky').
-include("bpe.hrl").
-include("api.hrl").
-include_lib("kvs/include/cursors.hrl").
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

add_trace(Proc,Name,Time,Task) ->
    Key = "/bpe/hist/" ++ Proc#process.id,
    Writer = kvs:writer(Key),
    kvs:append(Proc,"/bpe/proc"),
    kvs:append(#hist{ id = {step,Writer#writer.count,Proc#process.id},
                    name = Name,
                    time = #ts{ time = Time},
                    docs = Proc#process.docs,
                    task = Task}, Key).

add_error(Proc,Name,Time,Task) ->
    Key = "/bpe/error-hist/" ++ Proc#process.id,
    Writer = kvs:writer(Key),
    %%kvs:append(Proc,"/bpe/proc"),
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

    case Hist of empty -> add_trace(Proc,[],calendar:local_time(),Task),
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
         {error,Reason} -> {error,Reason} end.

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

errors(ProcId) -> kvs:feed("/bpe/error-hist/" ++ ProcId).

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

processFlow(#process{}=Proc) -> processSched(sched_head(Proc#process.id),Proc).

processSched(#sched{state=[]},Proc) -> {stop,normal,'Final',Proc};
processSched(#sched{} = Sched,Proc) ->
    Flow = lists:keyfind(flowId(Sched), #sequenceFlow.name, Proc#process.flows),
    SourceTask = lists:keyfind(Flow#sequenceFlow.source, #task.name, tasks(Proc)),
    TargetTask = lists:keyfind(Flow#sequenceFlow.target, #task.name, tasks(Proc)),
    Module = element(#task.module, SourceTask),
    Autorized = Module:auth(element(#task.roles, SourceTask)),
    processAuthorized(Autorized,SourceTask,TargetTask,Flow,Sched,Proc).

processAuthorized(false,SourceTask,_TargetTask,Flow,_Sched,Proc) ->
    add_error(Proc,"Access denied",calendar:local_time(),Flow),
    {reply, {error, "Access denied", SourceTask}, Proc};
processAuthorized(true,_,Task,Flow,#sched{id=SchedId, pointer=Pointer, state=Threads},Proc) ->
    Inserted = get_inserted(Task, Flow, SchedId),
    NewThreads = lists:sublist(Threads, Pointer-1) ++ Inserted ++ lists:nthtail(Pointer, Threads),
    NewPointer = if Pointer == length(Threads) -> 1; true -> Pointer + length(Inserted) end,
    add_sched(Proc, NewPointer, NewThreads),
    #sequenceFlow{name=Next, source=Src,target=Dst} = Flow,
    Resp = {Status,{Reason,_Reply},State}
         = bpe_task:task_action(element(#task.module, Task),Src,Dst,Proc),
    add_trace(State,[],calendar:local_time(),Flow),
    bpe_proc:debug(State,Next,Src,Dst,Status,Reason),
    Resp.

get_inserted(#gateway{type=Type, in=In, out=Out}, Flow, ScedId) when Type == inclusive;
                                                                     Type == parallel ->
    case check_all_flows(In -- [Flow#sequenceFlow.name], ScedId) of true -> Out; false -> [] end;
get_inserted(#gateway{type=exclusive, out=Out},_,_) -> first_matched_flow(Out);
%%By default we will handle any unmatched task the same way as an exlusive gateway
get_inserted(T,_,_) -> first_matched_flow(element(#task.out, T)).

check_all_flows([], _) -> true;
check_all_flows(_, #step{id = -1}) -> false;
check_all_flows(Needed, ScedId=#step{id=Id}) ->
    check_all_flows(Needed -- [flowId(sched(ScedId))], ScedId#step{id = Id-1}).

first_matched_flow([]) -> [];
first_matched_flow([H | Flows]) -> 
    case check_flow_condition(H) of true -> [H]; false -> first_matched_flow(Flows) end.

check_flow_condition(_Flow) -> true. %%TODO: implement check of Flow#sequenceFlow.condition

flowId(#sched{state=Flows, pointer=N}) -> lists:nth(N, Flows).
