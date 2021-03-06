%% Copyright (c) 2015, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(gun_ws).

-export([init/5]).
-export([handle/2]).
-export([send/2]).

-record(payload, {
	type = undefined :: cow_ws:frame_type(),
	rsv = undefined :: cow_ws:rsv(),
	len = undefined :: non_neg_integer(),
	mask_key = undefined :: cow_ws:mask_key(),
	close_code = undefined :: undefined | cow_ws:close_code(),
	unmasked = <<>> :: binary(),
	unmasked_len = 0 :: non_neg_integer()
}).

-record(ws_state, {
	owner :: pid(),
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	buffer = <<>> :: binary(),
	in = head :: head | #payload{} | close,
	frag_state = undefined :: cow_ws:frag_state(),
	frag_buffer = <<>> :: binary(),
	utf8_state = 0 :: cow_ws:utf8_state(),
	extensions = #{} :: cow_ws:extensions()
}).

%% @todo Protocols
init(Owner, Socket, Transport, Extensions, _Protocols) ->
	Owner ! {gun_ws_upgrade, self(), ok},
	{upgrade, ?MODULE, #ws_state{owner=Owner, socket=Socket, transport=Transport, extensions=Extensions}}.

%% Do not handle anything if we received a close frame.
handle(_, State=#ws_state{in=close}) ->
	State;
%% Shortcut for common case when Data is empty after processing a frame.
handle(<<>>, State=#ws_state{in=head}) ->
	State;
handle(Data, State=#ws_state{buffer=Buffer, in=head, frag_state=FragState, extensions=Extensions}) ->
	Data2 = << Buffer/binary, Data/binary >>,
	case cow_ws:parse_header(Data2, Extensions, FragState) of
		{Type, FragState2, Rsv, Len, MaskKey, Rest} ->
			handle(Rest, State#ws_state{buffer= <<>>,
				in=#payload{type=Type, rsv=Rsv, len=Len, mask_key=MaskKey}, frag_state=FragState2});
		more ->
			State#ws_state{buffer=Data2};
		error ->
			close({error, badframe}, State)
	end;
handle(Data, State=#ws_state{in=In=#payload{type=Type, rsv=Rsv, len=Len, mask_key=MaskKey, close_code=CloseCode,
		unmasked=Unmasked, unmasked_len=UnmaskedLen}, frag_state=FragState, utf8_state=Utf8State, extensions=Extensions}) ->
	case cow_ws:parse_payload(Data, MaskKey, Utf8State, UnmaskedLen, Type, Len, FragState, Extensions, Rsv) of
		{ok, CloseCode2, Payload, Utf8State2, Rest} ->
			dispatch(Rest, State#ws_state{in=head, utf8_state=Utf8State2}, Type, << Unmasked/binary, Payload/binary >>, CloseCode2);
		{ok, Payload, Utf8State2, Rest} ->
			dispatch(Rest, State#ws_state{in=head, utf8_state=Utf8State2}, Type, << Unmasked/binary, Payload/binary >>, CloseCode);
		{more, CloseCode2, Payload, Utf8State2} ->
			State#ws_state{in=In#payload{close_code=CloseCode2, unmasked= << Unmasked/binary, Payload/binary >>,
				len=Len - byte_size(Data), unmasked_len=2 + byte_size(Data)}, utf8_state=Utf8State2};
		{more, Payload, Utf8State2} ->
			State#ws_state{in=In#payload{unmasked= << Unmasked/binary, Payload/binary >>,
				len=Len - byte_size(Data), unmasked_len=UnmaskedLen + byte_size(Data)}, utf8_state=Utf8State2};
		Error = {error, _Reason} ->
			close(Error, State)
	end.

dispatch(Rest, State=#ws_state{owner=Owner, frag_state=FragState, frag_buffer=SoFar},
		Type0, Payload0, CloseCode0) ->
	case cow_ws:make_frame(Type0, Payload0, CloseCode0, FragState) of
		{fragment, nofin, _, Payload} ->
			handle(Rest, State#ws_state{frag_buffer= << SoFar/binary, Payload/binary >>});
		{fragment, fin, Type, Payload} ->
			Owner ! {gun_ws, self(), {Type, << SoFar/binary, Payload/binary >>}},
			handle(Rest, State#ws_state{frag_state=undefined, frag_buffer= <<>>});
		ping ->
			State2 = send(pong, State),
			handle(Rest, State2);
		{ping, Payload} ->
			State2 = send({pong, Payload}, State),
			handle(Rest, State2);
		pong ->
			handle(Rest, State);
		{pong, _} ->
			handle(Rest, State);
		Frame ->
			Owner ! {gun_ws, self(), Frame},
			case Frame of
				close -> handle(Rest, State#ws_state{in=close});
				{close, _, _} -> handle(Rest, State#ws_state{in=close});
				_ -> handle(Rest, State)
			end
	end.

close(Reason, State) ->
	case Reason of
		Normal when Normal =:= stop; Normal =:= timeout ->
			send({close, 1000, <<>>}, State);
		{error, badframe} ->
			send({close, 1002, <<>>}, State);
		{error, badencoding} ->
			send({close, 1007, <<>>}, State)
	end.

send(Frame, State=#ws_state{socket=Socket, transport=Transport, extensions=Extensions}) ->
	Transport:send(Socket, cow_ws:masked_frame(Frame, Extensions)),
	case Frame of
		close -> close;
		{close, _, _} -> close;
		_ -> State
	end.
