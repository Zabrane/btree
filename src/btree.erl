%%%----------------------------------------------------------------
%%%
%%% File        : btree.erl
%%% Author      : Mikael Pettersson <mikael.pettersson@klarna.com>
%%% Description : Erlang implementation of B-tree sets
%%%
%%% Copyright (c) 2016 Klarna AB
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%
%%%----------------------------------------------------------------
%%% 
%%% Implementation notes:
%%%
%%% - Initially based on [Wirth76].
%%% - Converted from Pascal to C, and then to Erlang.  The Erlang
%%%   version uses tuples in lieu of arrays.
%%% - I/O of pages is made explicit.
%%% - Search is separated from insertion.  Search returns a stack of
%%%   pages and indices recording the path from the root to the key.
%%%   Insertion uses that stack to navigate the tree when rewriting it.
%%% - Deletion is tricky enough that the recursive structure of the
%%%   original code is kept as-is.  A local cache is used to avoid
%%%   redundant I/Os.
%%% - Our use cases only want sets, so this does not associate
%%%   attributes with the keys.
%%%
%%%----------------------------------------------------------------
%%%
%%% References:
%%%
%%% [BM72] R. Bayer and E. McCreight, "Organization and Maintenance of
%%% Large Ordered Indexes", Acta Informatica, Vol. 1, Fasc. 3, pp. 173--189,
%%% 1972.
%%%
%%% [Wirth76] Niklaus Wirth, "Algorithms + Data Structures = Programs",
%%% Program 4.7, pp 252--257, Prentice-Hall, 1976.
%%%
%%% [Comer79] Douglas Comer, "The Ubiquitous B-Tree", Computing Surveys,
%%% Vol. 11, No. 2, pp 121--137, ACM, June 1979.
%%%
%%%----------------------------------------------------------------

-module(btree).
-export([ new/1
        , member/3
        , all_keys/2
        , insert/3
        , delete/3
        , mkio/5
        ]).

-export([check/2, print/2]). % for debugging only

%%%_* Types and macros =========================================================

%-define(DEBUG, true).
-ifdef(DEBUG).
-define(dbg(Fmt, Args), io:format(Fmt, Args)).
-else.
-define(dbg(Fmt, Args), ok).
-endif.

%% A page id is an integer > 0.
%% In references to pages, [] denotes an absent page ([] has a smaller external
%% representation than 0 or -1).

-type pageid() :: pos_integer().
-define(NOPAGEID, []).
-type pageid_opt() :: pageid() | ?NOPAGEID.

%% An item is a pair of a key and a page reference.
%% FIXME: drop tag to reduce storage
%% FIXME: inline as 2 consecutive elements in the page's E vector

-record(item,
        { k :: term()
        , p :: pageid_opt() % subtree with keys k' > k
        }).

%% A page is an array of m keys and m+1 page references, constrained
%% by m =< 2N, and m >= N except for the root page.

-record(page, % m == size(e)
        { pageid :: pageid()
        , p0 :: pageid_opt() % subtree with keys k' < (element(1, e))#item.k
        , e :: {#item{}}
        }).

-record(btree,
        { order :: pos_integer() % aka N
        , root :: pageid_opt()
        }).

%%%_* Creating an empty B-tree =================================================

new(N) when is_integer(N), N >= 2 ->
  #btree{order = N, root = ?NOPAGEID}.

%%%_* Membership check =========================================================
%%%
%%% Check if a key is present in a B-tree.  Return true if it is, false otherwise.

member(IO, X, #btree{root = A}) ->
  case search(IO, X, A) of
    {true, _P, _K, _Path} -> true;
    {false, _Path} -> false
  end.

%%%_* B-tree Search ============================================================
%%%
%%% Search a B-tree for key X.
%%% Return {true, P, K, Path} if found, where P is the page containing X
%%% at index K, and Path is a list of {Q,R} pairs listing, in reverse, the
%%% sequence of pages and indexes followed from the root to P.
%%% If not found, return {false, Path}.

search(IO, X, A) ->
  search(IO, X, A, []).

search(_IO, _X, ?NOPAGEID, Path) ->
  {false, Path};
search(IO, X, A, Path) ->
  #page{p0 = P0, e = E} = P = page_read(IO, A),
  case binsearch(E, X) of
    {found, K} ->
      {true, P, K, Path};
    {not_found, R} ->
      Q =
        if R =:= 0 -> P0;
           true -> (element(R, E))#item.p
        end,
      search(IO, X, Q, [{P, R} | Path])
  end.

%%%_* Binary search within a page ==============================================
%%%
%%% Search a page's item vector E for key X.
%%% Return {found, K} if found at index K,
%%% otherwise {not_found, R} [FIXME: proper defn of R].

binsearch(E, X) ->
  binsearch(E, X, 1, size(E)).
binsearch(E, X, L, R) when R >= L ->
  K = (L + R) div 2,
  KX = (element(K, E))#item.k,
  if X < KX -> binsearch(E, X, L, K - 1);
     X =:= KX -> {found, K};
     true -> binsearch(E, X, K + 1, R)
  end;
binsearch(_E, _X, _L, R) ->
  {not_found, R}.

%%%_* B-tree all_keys ==========================================================

all_keys(IO, #btree{root = A}) ->
  all_keys_page(IO, A, []).

all_keys_page(_IO, ?NOPAGEID, L) -> L;
all_keys_page(IO, A, L) ->
  #page{p0 = P0, e = E} = page_read(IO, A),
  all_keys_elements(IO, E, 1, all_keys_page(IO, P0, L)).

all_keys_elements(_IO, E, I, L) when I > size(E) -> L;
all_keys_elements(IO, E, I, L) ->
  #item{k = K, p = P} = element(I, E),
  all_keys_elements(IO, E, I + 1, all_keys_page(IO, P, [K | L])).

%%%_* Insertion into a B-tree ==================================================

insert(IO, X, Btree = #btree{order = N, root = Root}) ->
  case search(IO, X, Root) of
    {true, _P, _K, _Path} ->
      %% Nothing to do for sets.  For mappings, update the page if the
      %% key's attributes have changed.
      Btree;
    {false, Path} ->
      U = #item{k = X, p = ?NOPAGEID},
      case insert(IO, N, U, Path, Root) of
        false ->
          Btree;
        NewRoot ->
          Btree#btree{root = NewRoot}
      end
  end.

insert(IO, _N, U, [], Root) ->
  ?dbg("insert(~p, ~p, ~p, ~p)~n", [_N,U,[],Root]),
  PageId = page_allocate(IO),
  Page = #page{pageid = PageId, p0 = Root, e = {U}},
  page_write(IO, Page),
  PageId;
insert(IO, N, U, [{A, R} | Path], Root) ->
  ?dbg("insert(~p, ~p, ~p, ~p)~n", [N,U,[{A,R}|Path],Root]),
  E = A#page.e,
  if size(E) < 2 * N ->
      E2 = erlang:insert_element(R + 1, E, U),
      A2 = A#page{e = E2},
      page_write(IO, A2),
      false;
     true ->
      %% Page A is full; split it and continue with the emerging item V.
      {V, AE, BE} = split(N, U, E, R),
      ?dbg("split(~p, ~p, ~p, ~p)~n-> {~p, ~p, ~p}~n", [N,U,E,R,V,AE,BE]),
      A2 = A#page{e = AE},
      BPageId = page_allocate(IO),
      B = #page{pageid = BPageId, p0 = V#item.p, e = BE},
      page_write(IO, A2),
      page_write(IO, B),
      insert(IO, N, V#item{p = BPageId}, Path, Root)
  end.

split(N, U, E, R) ->
  if R =:= N ->
      {AE, BE} = lists:split(N, tuple_to_list(E)),
      {U, list_to_tuple(AE), list_to_tuple(BE)};
     R < N ->
      %% insert U in left page
      V = element(N, E),
      {AE, [_V | BE]} = lists:split(N - 1, tuple_to_list(E)),
      {AE1, AE2} = lists:split(R, AE),
      {V, list_to_tuple(AE1 ++ [U] ++ AE2), list_to_tuple(BE)};
     true ->
      %% insert U in right page
      R2 = R - N,
      V = element(N + 1, E),
      {AE, BE} = lists:split(N, tuple_to_list(E)),
      {BE1, BE2} = lists:split(R2 - 1, BE),
      {V, list_to_tuple(AE), list_to_tuple(BE1 ++ [U] ++ BE2)}
  end.

%%%_* Deletion in a B-tree =====================================================
%%%
%%% Deletion sometimes inspects and updates pages multiple times, so we use a
%%% simple cache to avoid redundant I/O operations here.

delete(IO, X, Btree) ->
  Cache1 = mkcache(IO),
  {Cache2, Btree2} = delete_1(Cache1, X, Btree),
  cache_flush(Cache2),
  Btree2.

delete_1(Cache1, X, Btree = #btree{order = N, root = RootPageId}) ->
  case delete(Cache1, N, X, RootPageId) of
    {Cache2, true} ->
      %% base page size was reduced
      {Cache3, #page{p0 = P0, e = E}} = cache_read(Cache2, RootPageId),
      if size(E) =:= 0 ->
          Cache4 = cache_delete(Cache3, RootPageId),
          {Cache4, Btree#btree{root = P0}};
         true ->
          {Cache3, Btree}
      end;
    {Cache2, false} ->
      {Cache2, Btree}
  end.

%%% Search and delete key X in B-tree A; if a page underflow is
%%% necessary, balance with adjacent page if possible, otherwise merge;
%%% return true if page A becomes undersize.
delete(Cache1, N, X, APageId) ->
  if APageId =:= ?NOPAGEID ->
      ?dbg("delete(~p, ~p)~n", [X, []]),
      false;
     true ->
      {Cache2, A = #page{p0 = AP0, e = AE}} = cache_read(Cache1, APageId),
      ?dbg("delete(~p, ~p)~n", [X, A]),
      case binsearch(AE, X) of
        {found, K} ->
          %% found, now delete a^.e[k]
          R = K - 1,
          QPageId =
            if R =:= 0 -> AP0;
               true -> (element(R, AE))#item.p
            end,
          if QPageId =:= ?NOPAGEID ->
              %% a is a terminal page
              AE2 = erlang:delete_element(K, AE),
              Cache3 = cache_write(Cache2, A#page{e = AE2}),
              {Cache3, size(AE2) < N};
             true ->
              case del(Cache2, N, QPageId, APageId, K) of
                {Cache3, true} ->
                  underflow(Cache3, N, APageId, QPageId, R);
                {Cache3, false} ->
                  {Cache3, false}
              end
          end;
        {not_found, R} ->
          QPageId =
            if R =:= 0 -> AP0;
               true -> (element(R, AE))#item.p
            end,
          case delete(Cache2, N, X, QPageId) of
            {Cache3, true} ->
              underflow(Cache3, N, APageId, QPageId, R);
            {Cache3, false} ->
              {Cache3, false}
          end
      end
  end.

del(Cache1, N, PPageId, APageId, K) ->
  {Cache2, P = #page{e = PE}} = cache_read(Cache1, PPageId),
  ?dbg("del(~p, ~p, ~p)~n", [P, APageId, K]),
  PEM = element(size(PE), PE),
  QPageId = PEM#item.p,
  if QPageId =/= ?NOPAGEID ->
      case del(Cache2, N, QPageId, APageId, K) of
        {Cache3, true} ->
          underflow(Cache3, N, PPageId, QPageId, size(PE));
        {Cache3, false} ->
          {Cache3, false}
      end;
     true ->
      {Cache3, A = #page{e = AE}} = cache_read(Cache2, APageId),
      %% Wirth's code appears to perform several reundant assignments in this case.
      AE2 = setelement(K, AE, (element(K, AE))#item{k = PEM#item.k}),
      PE2 = erlang:delete_element(size(PE), PE),
      Cache4 = cache_write(Cache3, A#page{e = AE2}),
      Cache5 = cache_write(Cache4, P#page{e = PE2}),
      {Cache5, size(PE2) < N}
  end.

%% Page A, referenced from page C at index S, is undersize (size(E) == N-1).
%% Fix that by borrowing from or merging with an adjacent page B.
%% Return true if C becomes undersize, false otherwise.
underflow(Cache1, N, CPageId, APageId, S) ->
  {Cache2, C = #page{p0 = CP0, e = CE}} = cache_read(Cache1, CPageId),
  {Cache3, A = #page{p0 = AP0, e = AE}} = cache_read(Cache2, APageId),
  ?dbg("underflow(~p, ~p, ~p)~n", [C, A, S]),
  if S < size(CE) ->
      %% b = page to the right of a
      S1 = S + 1,
      BPageId = (element(S1, CE))#item.p,
      {Cache4, B = #page{p0 = BP0, e = BE}} = cache_read(Cache3, BPageId),
      MB = size(BE),
      K = (MB - N + 1) div 2,
      %% k = no. of items available on adjacent page b
      U = #item{k = (element(S1, CE))#item.k, p = BP0},
      if K > 0 ->
          %% move k items from b to a
          %% (actually only k-1 items, 1 is moved to c)
          {BE1, [#item{k = BEKk, p = BEKp} | BE2]} = lists:split(K - 1, tuple_to_list(BE)),
          AE2 = list_to_tuple(tuple_to_list(AE) ++ [U] ++ BE1),
          CE2 = setelement(S1, CE, #item{k = BEKk, p = BPageId}),
          Cache5 = cache_write(Cache4, A#page{e = AE2}),
          Cache6 = cache_write(Cache5, C#page{e = CE2}),
          Cache7 = cache_write(Cache6, B#page{p0 = BEKp, e = list_to_tuple(BE2)}),
          {Cache7, false};
         true ->
          %% merge pages a and b
          AE2 = list_to_tuple(tuple_to_list(AE) ++ [U] ++ tuple_to_list(BE)),
          CE2 = erlang:delete_element(S1, CE),
          Cache5 = cache_write(Cache4, A#page{e = AE2}),
          Cache6 = cache_write(Cache5, C#page{e = CE2}),
          Cache7 = cache_delete(Cache6, BPageId),
          {Cache7, size(CE2) < N}
      end;
     true ->
      %% b = page to the left of a
      BPageId =
        if S =:= 1 -> CP0;
           true -> (element(S - 1, CE))#item.p
        end,
      {Cache4, B = #page{e = BE}} = cache_read(Cache3, BPageId),
      MB = size(BE) + 1,
      K = (MB - N) div 2,
      if K > 0 ->
          %% move k items from page b to a
          U = #item{k = (element(S, CE))#item.k, p = AP0},
          MB2 = MB - K,
          {BE1, [#item{k = BEBM2k, p = BEMB2p} | BE2]} = lists:split(MB2 - 1, tuple_to_list(BE)),
          AE2 = list_to_tuple(BE2 ++ [U] ++ tuple_to_list(AE)),
          CE2 = setelement(S, CE, #item{k = BEBM2k, p = APageId}),
          Cache5 = cache_write(Cache4, A#page{p0 = BEMB2p, e = AE2}),
          Cache6 = cache_write(Cache5, B#page{e = list_to_tuple(BE1)}),
          Cache7 = cache_write(Cache6, C#page{e = CE2}),
          {Cache7, false};
         true ->
          %% merge pages a and b
          U = #item{k = (element(S, CE))#item.k, p = AP0},
          BE2 = list_to_tuple(tuple_to_list(BE) ++ [U] ++ tuple_to_list(AE)),
          Cache5 = cache_write(Cache4, B#page{e = BE2}),
          Cache6 = cache_write(Cache5, C#page{e = erlang:delete_element(S, CE)}),
          Cache7 = cache_delete(Cache6, APageId),
          {Cache7, (S - 1) < N}
      end
  end.

%%%_* Page I/O cache for delete ================================================
%%%
%%% The B-trees are expected to be shallow, so the number of pages touched
%%% during delete will be few.  Therefore, the cache is simply a list.
%%%
%%% INV: There is at most one entry per PageId in the cache.

%-define(NOCACHE, true).
-ifdef(NOCACHE).

mkcache(IO)              -> IO.
cache_flush(_IO)         -> ok.
cache_read(IO, PageId)   -> {IO, page_read(IO, PageId)}.
cache_write(IO, Page)    -> page_write(IO, Page), IO.
cache_delete(IO, PageId) -> page_delete(IO, PageId), IO.

-else. % not NOCACHE

-record(cache, {io, entries}).

mkcache(IO) ->
  #cache{io = IO, entries = []}.

cache_flush(#cache{io = IO, entries = Entries}) ->
  [case Entry of
     {_PageId, clean, _Page} -> ok;
     {_PageId, dirty, Page} -> page_write(IO, Page);
     {PageId, deleted} -> page_delete(IO, PageId)
   end || Entry <- Entries],
  ok.

cache_read(Cache = #cache{io = IO, entries = Entries}, PageId) ->
  case lists:keyfind(PageId, 1, Entries) of
    {_PageId, clean, Page} -> {Cache, Page};
    {_PageId, dirty, Page} -> {Cache, Page};
    %% deliberate crash if deleted
    false ->
      Page = page_read(IO, PageId),
      NewEntries = [{PageId, clean, Page} | Entries],
      {Cache#cache{entries = NewEntries}, Page}
  end.

cache_write(Cache = #cache{entries = Entries},
            Page = #page{pageid = PageId}) ->
  NewEntries = lists:keystore(PageId, 1, Entries, {PageId, dirty, Page}),
  Cache#cache{entries = NewEntries}.

cache_delete(Cache = #cache{entries = Entries}, PageId) ->
  NewEntries = lists:keystore(PageId, 1, Entries, {PageId, deleted}),
  Cache#cache{entries = NewEntries}.

-endif. % not NOCACHE

%%%_* Page I/O =================================================================
%%%
%%% I/O is done by client-provided callbacks.

-record(io,
        { handle
        , read
        , write
        , allocate
        , delete
        }).

mkio(Handle, Read, Write, Allocate, Delete) ->
  #io{handle = Handle, read = Read, write = Write, allocate = Allocate,
      delete = Delete}.

page_read(#io{handle = Handle, read = Read}, PageId) ->
  ?dbg("page_read ~p~n", [PageId]),
  {ok, {P0, E}} = Read(Handle, PageId),
  #page{pageid = PageId, p0 = P0, e = E}.

page_write(#io{handle = Handle, write = Write}, Page) ->
  #page{pageid = PageId, p0 = P0, e = E} = Page,
  ?dbg("page_write ~p~n", [Page]),
  ok = Write(Handle, PageId, {P0, E}).

page_allocate(#io{handle = Handle, allocate = Allocate}) ->
  {ok, PageId} = Allocate(Handle),
  ?dbg("page_allocate = ~p~n", [PageId]),
  PageId.

page_delete(#io{handle = Handle, delete = Delete}, PageId) ->
  ?dbg("page_delete ~p~n", [PageId]),
  ok = Delete(Handle, PageId).

%%%_* Checking a B-tree (for debugging) ========================================

check(IO, #btree{order = N, root = A}) ->
  LowerBound = false,
  IsRoot = true,
  _LowerBound2 = check_page(IO, N, A, LowerBound, IsRoot),
  ok.

check_page(_IO, _N, ?NOPAGEID, LowerBound, _IsRoot) -> LowerBound;
check_page(IO, N, PageId, LowerBound, IsRoot) ->
  #page{p0 = P0, e = E} = page_read(IO, PageId),
  %% check page size
  true = size(E) =< 2 * N,
  true = IsRoot orelse size(E) >= N,
  %% check key order and subtrees
  LowerBound2 = check_page(IO, N, P0, LowerBound, false),
  check_elements(IO, N, E, 1, LowerBound2).

check_elements(_IO, _N, E, I, LowerBound) when I > size(E) -> LowerBound;
check_elements(IO, N, E, I, LowerBound) ->
  #item{k = K, p = P} = element(I, E),
  check_key(K, LowerBound),
  LowerBound2 = {ok, K},
  LowerBound3 = check_page(IO, N, P, LowerBound2, false),
  check_elements(IO, N, E, I + 1, LowerBound3).

check_key(_K, false) -> true;
check_key(K, {ok, LowerBound}) -> true = K > LowerBound.

%%%_* Printing a B-tree (for debugging) ========================================

print(IO, #btree{root = A}) ->
  print(IO, A, 1).

print(_IO, ?NOPAGEID, _L) ->
  ok;
print(IO, PageId, L) ->
  #page{p0 = P0, e = E} = page_read(IO, PageId),
  [io:format("     ") || _I <- lists:seq(1, L)],
  [io:format(" ~4w", [(element(I, E))#item.k]) || I <- lists:seq(1, size(E))],
  io:format("~n"),
  print(IO, P0, L + 1),
  [print(IO, (element(I, E))#item.p, L + 1) || I <- lists:seq(1, size(E))],
  ok.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
