-module(bpe_account).
-author('Maxim Sokhatsky').
-include("bpe.hrl").
-include("doc.hrl").
-export([def/0]).
-compile(export_all).

def() ->
    #process { name = 'IBAN Account',
        flows = [
            #sequenceFlow{name='->Init', source='Created',   target='Init'},
            #sequenceFlow{name='->Upload', source='Init',      target='Upload'},
            #sequenceFlow{name='->Payment', source='Upload',    target='Payment'},
            #sequenceFlow{name='Payment->Signatory', source='Payment',   target='Signatory'},
            #sequenceFlow{name='Payment->Process', source='Payment',   target='Process'},
            #sequenceFlow{name='Process-loop', source='Process',   target='Process'},
            #sequenceFlow{name='Process->Final', source='Process',   target='Final'},
            #sequenceFlow{name='Signatory->Process', source='Signatory', target='Process'},
            #sequenceFlow{name='Signatory->Final', source='Signatory', target='Final'} ],
        tasks = [
            #beginEvent  { name='Created',   module = bpe_account },
            #userTask    { name='Init',      module = bpe_account },
            #userTask    { name='Upload',    module = bpe_account },
            #userTask    { name='Signatory', module = bpe_account }, %%Looks like gateway
            #serviceTask { name='Payment',   module = bpe_account }, %%Looks like gateway
            #serviceTask { name='Process',   module = bpe_account }, %%Looks like gateway
            #endEvent    { name='Final',     module = bpe_account } ], %%Looks like gateway
        beginEvent = 'Created',
        endEvent = 'Final',
        events = [ #messageEvent{name='PaymentReceived'},
                   #boundaryEvent{name='*', timeout=#timeout{spec={0, {10, 0, 10}}}} ] }.

action({request,'Created',_}, Proc) ->
    {reply,Proc};

action({request,'Init',_}, Proc) ->
    {reply,Proc};

action({request,'Payment',_}, Proc) ->
    Payment = bpe:doc({payment_notification},Proc),
    case Payment of
         [] -> {reply,'Process',Proc#process{docs=[#tx{}]}};
          _ -> {reply,'Signatory',Proc} end;

action({request,'Signatory',_}, Proc) ->
    {reply,'Process',Proc};

action({request,'Process',_}, Proc) ->
    case bpe:doc(#close_account{},Proc) of
         #close_account{} -> {reply,'Final',Proc};
                        _ -> {reply,Proc} end;

action({request,'Upload',_}, Proc) ->
    {reply,Proc};

action({request,'Final',_}, Proc) ->
    {reply,Proc}.
