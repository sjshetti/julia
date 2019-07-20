include("lowering_tools.jl")

# Tests are organized by the Expr head which needs to be lowered.
@testset "Lowering" begin

@testset_desugar "ref end" begin
    # Indexing
    a[i]
    Top.getindex(a, i)

    a[i,j]
    Top.getindex(a, i, j)

    # Indexing with `end`
    a[end]
    Top.getindex(a, Top.lastindex(a))

    a[i,end]
    Top.getindex(a, i, Top.lastindex(a,2))

    # Nesting of `end`
    a[[end]]
    Top.getindex(a, Top.vect(Top.lastindex(a)))

    a[b[end] + end]
    Top.getindex(a, Top.getindex(b, Top.lastindex(b)) + Top.lastindex(a))

    a[f(end) + 1]
    Top.getindex(a, f(Top.lastindex(a)) + 1)

    # array expr is only emitted once if it can have side effects
    (f(x))[end]
    begin
        ssa1 = f(x)
        Top.getindex(ssa1, Top.lastindex(ssa1))
    end

    a[end][b[i]]
    begin
        ssa1 = Top.getindex(a, Top.lastindex(a))
        Top.getindex(ssa1, Top.getindex(b, i))
    end

    # `end` replacment for first agument of Expr(:ref)
    a[f(end)[i]]
    Top.getindex(a, begin
                     ssa1 = f(Top.lastindex(a))
                     Top.getindex(ssa1, i)
                 end)

    # Interaction of `end` with splatting
    a[I..., end, J..., end]
    Core._apply(Top.getindex, Core.tuple(a),
                I,
                Core.tuple(Top.lastindex(a, Top.:+(1, Top.length(I)))),
                J,
                Core.tuple(Top.lastindex(a, Top.:+(2, Top.length(J), Top.length(I)))))

    a[f(x)..., end]
    begin
        ssa1 = f(x)
        Core._apply(Top.getindex, Core.tuple(a),
                    ssa1,
                    Core.tuple(Top.lastindex(a, Top.:+(1, Top.length(ssa1)))))
    end
end

@testset_desugar "vect" begin
    # flisp: (in expand-table)
    [a,b]
    Top.vect(a,b)

    [a,b;c]
    @Expr(:error, "unexpected semicolon in array expression")

    [a=b,c]
    @Expr(:error, "misplaced assignment statement in `[a = b, c]`")
end

@testset_desugar "hcat vcat hvcat" begin
    # flisp: (lambda in expand-table)
    [a b]
    Top.hcat(a,b)

    [a; b]
    Top.vcat(a,b)

    T[a b]
    Top.typed_hcat(T, a,b)

    T[a; b]
    Top.typed_vcat(T, a,b)

    [a b; c]
    Top.hvcat(Core.tuple(2,1), a, b, c)

    T[a b; c]
    Top.typed_hvcat(T, Core.tuple(2,1), a, b, c)

    [a b=c]
    @Expr(:error, "misplaced assignment statement in `[a b = c]`")

    [a; b=c]
    @Expr(:error, "misplaced assignment statement in `[a; b = c]`")

    T[a b=c]
    @Expr(:error, "misplaced assignment statement in `T[a b = c]`")

    T[a; b=c]
    @Expr(:error, "misplaced assignment statement in `T[a; b = c]`")
end

@testset_desugar "tuple" begin
    (x,y)
    Core.tuple(x,y)

    (x=a,y=b)
    Core.apply_type(Core.NamedTuple, Core.tuple(:x, :y))(Core.tuple(a, b))

    # Expr(:parameters) version also works
    (;x=a,y=b)
    Core.apply_type(Core.NamedTuple, Core.tuple(:x, :y))(Core.tuple(a, b))

    # Mixed tuple + named tuple
    (1; x=a, y=b)
    @Expr(:error, "unexpected semicolon in tuple")
end

@testset_desugar "comparison" begin
    # flisp: (expand-compare-chain)
    a < b < c
    if a < b
        b < c
    else
        false
    end

    # Nested
    a < b > d <= e
    if a < b
        if b > d
            d <= e
        else
            false
        end
    else
        false
    end

    # Subexpressions
    a < b+c < d
    if (ssa1 = b+c; a < ssa1)
        ssa1 < d
    else
        false
    end

    # Interaction with broadcast syntax
    a < b .< c
    Top.materialize(Top.broadcasted(&, a < b, Top.broadcasted(<, b, c)))

    a .< b+c < d
    Top.materialize(Top.broadcasted(&,
                                    begin
                                        ssa1 = b+c
                                        # Is this a bug?
                                        Top.materialize(Top.broadcasted(<, a, ssa1))
                                    end,
                                    ssa1 < d))

    a < b+c .< d
    Top.materialize(Top.broadcasted(&,
                                    begin
                                        ssa1 = b+c
                                        a < ssa1
                                    end,
                                    Top.broadcasted(<, ssa1, d)))
end

@testset_desugar "|| &&" begin
    # flisp: (expand-or)
    a || b
    if a
        true
    else
        b
    end

    f(a) || f(b) || f(c)
    if f(a)
        true
    else
        if f(b)
            true
        else
            f(c)
        end
    end

    # flisp: (expand-and)
    a && b
    if a
        b
    else
        false
    end

    f(a) && f(b) && f(c)
    if f(a)
        if f(b)
            f(c)
        else
            false
        end
    else
        false
    end
end

@testset_desugar "' <: :>" begin
    a'
    Top.adjoint(a)

    # <: and >: are special Expr heads which need to be turned into Expr(:call)
    # when used as operators
    a <: b
    $(Expr(:call, :(<:), :a, :b))

    a >: b
    $(Expr(:call, :(>:), :a, :b))

end

@testset_desugar "\$ ... {}" begin
    $(Expr(:$, :x))
    @Expr(:error, "`\$` expression outside quote")

    x...
    @Expr(:error, "`...` expression outside call")

    {a, b}
    @Expr(:error, "{ } vector syntax is discontinued")

    {a; b}
    @Expr(:error, "{ } matrix syntax is discontinued")
end

@testset_desugar ". .=" begin
    # flisp: (expand-fuse-broadcast)

    # Property access
    a.b
    Top.getproperty(a, :b)

    a.b.c
    Top.getproperty(Top.getproperty(a, :b), :c)

    # Broadcast
    # Basic
    x .+ y
    Top.materialize(Top.broadcasted(+, x, y))

    f.(x)
    Top.materialize(Top.broadcasted(f, x))

    # Fusing
    f.(x) .+ g.(y)
    Top.materialize(Top.broadcasted(+, Top.broadcasted(f, x), Top.broadcasted(g, y)))

    # Keywords don't participate
    f.(x, a=1)
    Top.materialize(
        begin
            ssa1 = Top.broadcasted_kwsyntax
            ssa2 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
            Core.kwfunc(ssa1)(ssa2, ssa1, f, x)
        end
    )

    # Nesting
    f.(g(x))
    Top.materialize(Top.broadcasted(f, g(x)))

    f.(g(h.(x)))
    Top.materialize(Top.broadcasted(f, g(Top.materialize(Top.broadcasted(h, x)))))

    # In place
    x .= a
    Top.materialize!(x, Top.broadcasted(Top.identity, a))

    x .= f.(a)
    Top.materialize!(x, Top.broadcasted(f, a))

    x .+= a
    Top.materialize!(x, Top.broadcasted(+, x, a))
end

@testset_desugar "call" begin
    # zero arg call
    g[i]()
    Top.getindex(g, i)()

    # splatting
    f(i, j, v..., k)
    Core._apply(f, Core.tuple(i,j), v, Core.tuple(k))

    # keyword arguments
    f(x, a=1)
    begin
        ssa1 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
        Core.kwfunc(f)(ssa1, f, x)
    end

    f(x; a=1)
    begin
        ssa1 = (Core.apply_type(Core.NamedTuple, Core.tuple(:a)))(Core.tuple(1))
        (Core.kwfunc(f))(ssa1, f, x)
    end
end

@testset_desugar "ccall" begin
end

@testset_desugar "do" begin
    f(x) do y
        body(y)
    end
    f(begin
          local gsym1
          begin
              @Expr(:method, gsym1)
              @Expr(:method, gsym1, Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any), Core.svec()), @Expr(:lambda, [_self_, y], [], @Expr(:scope_block, body(y))))
              maybe_unused(gsym1)
          end
      end, x)

    f(x; a=1) do y
        body(y)
    end
    begin
        ssa1 = begin
            local gsym1
            begin
                @Expr(:method, gsym1)
                @Expr(:method, gsym1, Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any), Core.svec()), @Expr(:lambda, [_self_, y], [], @Expr(:scope_block, body(y))))
                maybe_unused(gsym1)
            end
        end
        begin
            ssa2 = (Core.apply_type(Core.NamedTuple, Core.tuple(:a)))(Core.tuple(1))
            (Core.kwfunc(f))(ssa2, f, ssa1, x)
        end
    end
end

@testset_desugar "+= .+= etc" begin
    # flisp: (lower-update-op)
    x += a
    x = x+a

    x::Int += a
    x = x::Int + a

    x[end] += a
    begin
        ssa1 = Top.lastindex(x)
        begin
            ssa2 = Top.getindex(x, ssa1) + a
            Top.setindex!(x, ssa2, ssa1)
            maybe_unused(ssa2)
        end
    end

    x[f(y)] += a
    begin
        ssa1 = f(y)
        begin
            ssa2 = Top.getindex(x, ssa1) + a
            Top.setindex!(x, ssa2, ssa1)
            maybe_unused(ssa2)
        end
    end

    # getproperty(x,y) only eval'd once.
    x.y.z += a
    begin
        ssa1 = Top.getproperty(x, :y)
        begin
            ssa2 = Top.getproperty(ssa1, :z) + a
            Top.setproperty!(ssa1, :z, ssa2)
            maybe_unused(ssa2)
        end
    end

    (x,y) .+= a
    begin
        ssa1 = Core.tuple(x, y)
        Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
    end

    [x y] .+= a
    begin
        ssa1 = Top.hcat(x, y)
        Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
    end

    (x+y) += 1
    @Expr(:error, "invalid assignment location `(x + y)`")
end

@testset_desugar "=" begin
    # flisp: (lambda in expand-table)

    # property notation
    a.b = c
    begin
        Top.setproperty!(a, :b, c)
        maybe_unused(c)
    end

    a.b.c = d
    begin
        ssa1 = Top.getproperty(a, :b)
        Top.setproperty!(ssa1, :c, d)
        maybe_unused(d)
    end

    # setindex
    a[i] = b
    begin
        Top.setindex!(a, b, i)
        maybe_unused(b)
    end

    a[i,end] = b+c
    begin
        ssa1 = b+c
        Top.setindex!(a, ssa1, i, Top.lastindex(a,2))
        maybe_unused(ssa1)
    end

    # Assignment chain; nontrivial rhs
    x = y = f(a)
    begin
        ssa1 = f(a)
        y = ssa1
        x = ssa1
        maybe_unused(ssa1)
    end

    # Multiple Assignment

    # Simple multiple assignment exact match
    (x,y) = (a,b)
    begin
        x = a
        y = b
        maybe_unused(Core.tuple(a,b))
    end

    # Destructuring
    (x,y) = a
    begin
        begin
            ssa1 = Top.indexed_iterate(a, 1)
            x = Core.getfield(ssa1, 1)
            gsym1 = Core.getfield(ssa1, 2)
            ssa1
        end
        begin
            ssa2 = Top.indexed_iterate(a, 2, gsym1)
            y = Core.getfield(ssa2, 1)
            ssa2
        end
        maybe_unused(a)
    end

    # Nested destructuring
    (x,(y,z)) = a
    begin
        begin
            ssa1 = Top.indexed_iterate(a, 1)
            x = Core.getfield(ssa1, 1)
            gsym1 = Core.getfield(ssa1, 2)
            ssa1
        end
        begin
            ssa2 = Top.indexed_iterate(a, 2, gsym1)
            begin
                ssa3 = Core.getfield(ssa2, 1)
                begin
                    ssa4 = Top.indexed_iterate(ssa3, 1)
                    y = Core.getfield(ssa4, 1)
                    gsym2 = Core.getfield(ssa4, 2)
                    ssa4
                end
                begin
                    ssa5 = Top.indexed_iterate(ssa3, 2, gsym2)
                    z = Core.getfield(ssa5, 1)
                    ssa5
                end
                maybe_unused(ssa3)
            end
            ssa2
        end
        maybe_unused(a)
    end

    # type decl
    x::T = a
    begin
        @Expr :decl x T
        x = a
    end

    # type aliases
    A{T} = B{T}
    begin
        @Expr :const_if_global A
        A = @Expr(:scope_block,
                  begin
                      @Expr :local_def T
                      T = Core.TypeVar(:T)
                      Core.UnionAll(T, Core.apply_type(B, T))
                  end)
    end

    # Short form function definitions
    f(x) = body(x)
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
              @Expr(:lambda, [_self_, x], [],
                    @Expr(:scope_block,
                          body(x))))
        maybe_unused(f)
    end

    # Invalid assignments
    1 = a
    @Expr(:error, "invalid assignment location `1`")

    true = a
    @Expr(:error, "invalid assignment location `true`")

    "str" = a
    @Expr(:error, "invalid assignment location `\"str\"`")

    [x y] = c
    @Expr(:error, "invalid assignment location `[x y]`")

    a[x y] = c
    @Expr(:error, "invalid spacing in left side of indexed assignment")

    a[x;y] = c
    @Expr(:error, "unexpected `;` in left side of indexed assignment")

    [x;y] = c
    @Expr(:error, "use `(a, b) = ...` to assign multiple values")

    # Old deprecation (6575e12ba46)
    x.(y)=c
    @Expr(:error, "invalid syntax `x.(y) = ...`")
end

@testset_desugar "const local global" begin
    # flisp: (expand-decls) (expand-local-or-global-decl) (expand-const-decl)
    # const
    const x=a
    begin
        @Expr :const x    # `const x` is invalid surface syntax
        x = a
    end

    const x,y = a,b
    begin
        @Expr :const x
        @Expr :const y
        begin
            x = a
            y = b
            maybe_unused(Core.tuple(a,b))
        end
    end

    # local
    local x, y
    begin
        local y
        local x
    end

    # Locals with initialization. Note parentheses are needed for this to parse
    # as individual assignments rather than multiple assignment.
    local (x=a), (y=b), z
    begin
        local z
        local y
        local x
        x = a
        y = b
    end

    # Multiple assignment form
    begin
        local x,y = a,b
    end
    begin
        local x
        local y
        begin
            x = a
            y = b
            maybe_unused(Core.tuple(a,b))
        end
    end

    # global
    global x, (y=a)
    begin
        global y
        global x
        y = a
    end
end

@testset_desugar "where" begin
    A{T} where T
    @Expr(:scope_block, begin
              @Expr(:local_def, T)
              T = Core.TypeVar(:T)
              Core.UnionAll(T, Core.apply_type(A, T))
          end)

    A{T} where T <: S
    @Expr(:scope_block, begin
              @Expr(:local_def, T)
              T = Core.TypeVar(:T, S)
              Core.UnionAll(T, Core.apply_type(A, T))
          end)

    A{T} where T >: S
    @Expr(:scope_block, begin
              @Expr(:local_def, T)
              T = Core.TypeVar(:T, S, Core.Any)
              Core.UnionAll(T, Core.apply_type(A, T))
          end)

    A{T} where S' <: T <: V'
    @Expr(:scope_block, begin
              @Expr(:local_def, T)
              T = Core.TypeVar(:T, Top.adjoint(S), Top.adjoint(V))
              Core.UnionAll(T, Core.apply_type(A, T))
          end)

    A{T} where S <: T <: V <: W
    @Expr(:error, "invalid variable expression in `where`")

    A{T} where S <: T < V
    @Expr(:error, "invalid bounds in `where`")

    A{T} where S < T <: V
    @Expr(:error, "invalid bounds in `where`")

    T where a <: T(x) <: b
    @Expr(:error, "invalid type parameter name `T(x)`")
end

@testset_desugar "let" begin
    # flisp: (expand-let)
    let x::Int
        body
    end
    @Expr(:scope_block, begin
              begin
                  local x
                  @Expr(:decl, x, Int)
              end
              body
          end)

    # Let without assignment
    let x,y
        body
    end
    @Expr(:scope_block,
          begin
              local x
              @Expr(:scope_block,
                    begin
                        local y
                        body
                    end)
          end)

    # Let with assignment
    let x=a, y=b
        body
    end
    @Expr(:scope_block,
          begin
              @Expr :local_def x
              x = a
              @Expr(:scope_block,
                    begin
                        @Expr :local_def y
                        y = b
                        body
                    end)
          end)

    # Let with function declaration
    let f(x) = 1
        body
    end
    @Expr(:scope_block,
          begin
              @Expr(:local_def, f)
              begin
                  @Expr(:method, f)
                  @Expr(:method, f,
                        Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
                        @Expr(:lambda, [_self_, x], [], @Expr(:scope_block, 1)))
              end
              body
          end)

    # Local recursive function
    let f(x) = f(x)
        body
    end
    @Expr(:scope_block, begin
              local f
              begin
                  @Expr(:method, f)
                  @Expr(:method, f,
                        Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
                        @Expr(:lambda, [_self_, x], [], @Expr(:scope_block, f(x))))
              end
              body
          end)

    # Let with existing var on rhs
    let x = x + a
        body
    end
    @Expr(:scope_block, begin
              ssa1 = x + a
              @Expr(:scope_block, begin
                        @Expr(:local_def, x)
                        x = ssa1
                        body
                    end)
          end)

    # Destructuring
    let (a, b) = (c, d)
        body
    end
    @Expr(:scope_block,
          begin
              @Expr(:local_def, a)
              @Expr(:local_def, b)
              begin
                  a = c
                  b = d
                  maybe_unused(Core.tuple(c, d))
              end
              body
          end)

    # Destructuring with existing vars on rhs
    let (a, b) = (a, d)
        body
    end
    begin
        ssa1 = Core.tuple(a, d)
        @Expr(:scope_block,
              begin
                  @Expr(:local_def, a)
                  @Expr(:local_def, b)
                  begin
                      begin
                          ssa2 = Top.indexed_iterate(ssa1, 1)
                          a = Core.getfield(ssa2, 1)
                          gsym1 = Core.getfield(ssa2, 2)
                          ssa2
                      end
                      begin
                          ssa3 = Top.indexed_iterate(ssa1, 2, gsym1)
                          b = Core.getfield(ssa3, 1)
                          ssa3
                      end
                      maybe_unused(ssa1)
                  end
                  body
              end)
    end

    # Other expressions in the variable list should produce an error
    let f(x)
        body
    end
    @Expr(:error, "invalid let syntax")

    let x[i] = a
    end
    @Expr(:error, "invalid let syntax")
end

@testset_desugar "block" begin
    $(Expr(:block))
    $nothing

    $(Expr(:block, :a))
    a
end

@testset_desugar "while for" begin
    # flisp: (expand-for) (lambda in expand-forms)
    while cond'
        body1'
        continue
        body2
        break
        body3
    end
    @Expr(:break_block, loop_exit,
          @Expr(:_while, Top.adjoint(cond),
                @Expr(:break_block, loop_cont,
                      @Expr(:scope_block, begin
                                Top.adjoint(body1)
                                @Expr :break loop_cont
                                body2
                                @Expr :break loop_exit
                                body3
                            end))))

    for i = a
        body1
        continue
        body2
        break
    end
    @Expr(:break_block, loop_exit,
          begin
              ssa1 = a
              gsym1 = Top.iterate(ssa1)
              if Top.not_int(Core.:(===)(gsym1, $nothing))
                  @Expr(:_do_while,
                        begin
                            @Expr(:break_block, loop_cont,
                                  @Expr(:scope_block,
                                        begin
                                            local i
                                            begin
                                                ssa2 = gsym1
                                                i = Core.getfield(ssa2, 1)
                                                ssa3 = Core.getfield(ssa2, 2)
                                                ssa2
                                            end
                                            begin
                                                body1
                                                @Expr :break loop_cont
                                                body2
                                                @Expr :break loop_exit
                                            end
                                        end))
                            gsym1 = Top.iterate(ssa1, ssa3)
                        end,
                        Top.not_int(Core.:(===)(gsym1, $nothing)))
              end
          end)

    # For loops with `outer`
    for outer i = a
        body
    end
    @Expr(:break_block, loop_exit,
          begin
              ssa1 = a
              gsym1 = Top.iterate(ssa1)
              @Expr(:require_existing_local, i)
              if Top.not_int(Core.:(===)(gsym1, $nothing))
                  @Expr(:_do_while,
                        begin
                            @Expr(:break_block, loop_cont,
                                  @Expr(:scope_block,
                                        begin
                                            begin
                                                ssa2 = gsym1
                                                i = Core.getfield(ssa2, 1)
                                                ssa3 = Core.getfield(ssa2, 2)
                                                ssa2
                                            end
                                            body
                                        end))
                            gsym1 = Top.iterate(ssa1, ssa3)
                        end,
                        Top.not_int(Core.:(===)(gsym1, $nothing)))
              end
          end)
end

@testset_desugar "try catch finally" begin
    # flisp: expand-try
    try
        a
    catch
        b
    end
    @Expr(:trycatch,
          @Expr(:scope_block, begin a end),
          @Expr(:scope_block, begin b end))

    try
        a
    catch exc
        b
    end
    @Expr(:trycatch,
          @Expr(:scope_block, begin a end),
          @Expr(:scope_block,
                begin
                    exc = @Expr(:the_exception)
                    b
                end))

    try
    catch exc
    end
    @Expr(:trycatch,
          @Expr(:scope_block, $nothing),
          @Expr(:scope_block, begin
                    exc = @Expr(:the_exception)
                    begin
                    end
                end))

    try
        a
    finally
        b
    end
    @Expr(:tryfinally,
          @Expr(:scope_block, begin a end),
          @Expr(:scope_block, begin b end))

    try
        a
    catch
        b
    finally
        c
    end
    @Expr(:tryfinally,
          @Expr(:trycatch,
                @Expr(:scope_block, begin a end),
                @Expr(:scope_block, begin b end)),
          @Expr(:scope_block, begin c end))

    # goto with label anywhere within try block is ok
    try
        begin
            let
                $(Expr(:symbolicgoto, :x))   # @goto x
            end
        end
        begin
            $(Expr(:symboliclabel, :x))  # @label x
        end
    finally
    end
    @Expr(:tryfinally,
          @Expr(:scope_block,
                begin
                    begin
                        @Expr(:scope_block,
                              @Expr(:symbolicgoto, x))
                    end
                    begin
                        @Expr(:symboliclabel, x)
                    end
                end),
          @Expr(:scope_block,
                begin
                end))

    # goto not allowed without associated label in try/finally
    try
        begin
            let
                $(Expr(:symbolicgoto, :x))   # @goto x
            end
        end
    finally
    end
    @Expr(:error, "goto from a try/finally block is not permitted")

    $(Expr(:try, :a, :b, :c, :d, :e))
    @Expr(:error, "invalid `try` form")
end

@testset_desugar "function" begin
    # Long form with argument annotations
    function f(x::T, y)
        body(x)
    end
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f), T, Core.Any), Core.svec()),
              @Expr(:lambda, [_self_, x, y], [],
                    @Expr(:scope_block,
                          body(x))))
        maybe_unused(f)
    end

    # Default arguments
    function f(x=a, y=b)
        body(x,y)
    end
    begin
        begin
            @Expr(:method, f)
            @Expr(:method, f,
                  Core.svec(Core.svec(Core.Typeof(f)), Core.svec()),
                  @Expr(:lambda, [_self_], [],
                        @Expr(:scope_block, _self_(a, b))))
            maybe_unused(f)
        end
        begin
            @Expr(:method, f)
            @Expr(:method, f,
                  Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
                  @Expr(:lambda, [_self_, x], [],
                        @Expr(:scope_block, _self_(x, b))))
            maybe_unused(f)
        end
        begin
            @Expr(:method, f)
            @Expr(:method, f,
                  Core.svec(Core.svec(Core.Typeof(f), Core.Any, Core.Any), Core.svec()),
                  @Expr(:lambda, [_self_, x, y], [],
                        @Expr(:scope_block, body(x, y))))
            maybe_unused(f)
        end
    end

    # Varargs
    function f(x, args...)
        body(x, args)
    end
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f), Core.Any,
                                  Core.apply_type(Vararg, Core.Any)), Core.svec()),
              @Expr(:lambda, [_self_, x, args], [],
                    @Expr(:scope_block, body(x, args))))
        maybe_unused(f)
    end

    # Keyword arguments
    function f(x; k1=v1, k2=v2)
        body
    end
    Core.ifelse(false, false,
        begin
            @Expr(:method, f)
            begin
                @Expr(:method, gsym1)
                @Expr(:method, gsym1,
                      Core.svec(Core.svec(Core.typeof(gsym1), Core.Any, Core.Any, Core.Typeof(f), Core.Any), Core.svec()),
                      @Expr(:lambda, [gsym1, k1, k2, _self_, x], [],
                            @Expr(:scope_block, body)))
                maybe_unused(gsym1)
            end
            begin
                @Expr(:method, f)
                @Expr(:method, f,
                      Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
                      @Expr(:lambda, [_self_, x], [],
                            @Expr(:scope_block, return gsym1(v1, v2, _self_, x))))
                maybe_unused(f)
            end
            begin
                @Expr(:method, f)
                @Expr(:method, f,
                      Core.svec(Core.svec(Core.kwftype(Core.Typeof(f)), Core.Any, Core.Typeof(f), Core.Any), Core.svec()),
                      @Expr(:lambda, [gsym2, gsym3, _self_, x], [],
                            @Expr(:scope_block,
                                  @Expr(:scope_block,
                                        begin
                                            @Expr(:local_def, k1)
                                            k1 = if Top.haskey(gsym3, :k1)
                                                Top.getindex(gsym3, :k1)
                                            else
                                                v1
                                            end
                                            @Expr(:scope_block, begin
                                                      @Expr(:local_def, k2)
                                                      k2 = if Top.haskey(gsym3, :k2)
                                                          Top.getindex(gsym3, :k2)
                                                      else
                                                          v2
                                                      end
                                                      begin
                                                          ssa1 = Top.pairs(Top.structdiff(gsym3, Core.apply_type(Core.NamedTuple, Core.tuple(:k1, :k2))))
                                                          if Top.isempty(ssa1)
                                                              $nothing
                                                          else
                                                              Top.kwerr(gsym3, _self_, x)
                                                          end
                                                          return gsym1(k1, k2, _self_, x)
                                                      end
                                                  end)
                                        end))))
                maybe_unused(f)
            end
            f
        end)

    # Return type declaration
    function f(x)::T
        body(x)
    end
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
              @Expr(:lambda, [_self_, x], [],
                    @Expr(:scope_block,
                          begin
                              ssa1 = T
                              @Expr(:meta, ret_type, ssa1)
                              body(x)
                          end)))
        maybe_unused(f)
    end

    # Anon functions
    (x,y)->body(x,y)
    begin
        local gsym1
        begin
            @Expr(:method, gsym1)
            @Expr(:method, gsym1,
                  Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any, Core.Any), Core.svec()),
                  @Expr(:lambda, [_self_, x, y], [],
                        @Expr(:scope_block, body(x, y))))
            maybe_unused(gsym1)
        end
    end

    # Where syntax
    function f(x::T, y::S) where {T <: S, S <: U}
        body(x, y)
    end
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              begin
                  ssa1 = Core.TypeVar(:T, S)
                  ssa2 = Core.TypeVar(:S, U)
                  Core.svec(Core.svec(Core.Typeof(f), ssa1, ssa2), Core.svec(ssa1, ssa2))
              end,
              @Expr(:lambda, [_self_, x, y], [], @Expr(:scope_block, body(x, y))))
        maybe_unused(f)
    end

    # Type constraints
    #=
    function f(x::T{<:S})
        body(x, y)
    end
    begin
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f),
                                  @Expr(:scope_block,
                                        begin
                                            @Expr(:local_def, gsym1)
                                            gsym1 = Core.TypeVar(Symbol("#s167"), S)
                                            Core.UnionAll(gsym1, Core.apply_type(T, gsym1))
                                        end)), Core.svec()),
              @Expr(:lambda, [_self_, x], [], @Expr(:scope_block, body(x, y))))
        maybe_unused(f)
    end
    FIXME
    =#

    # Invalid function names
    ccall(x)=body
    @Expr(:error, "invalid function name `ccall`")

    cglobal(x)=body
    @Expr(:error, "invalid function name `cglobal`")

    true(x)=body
    @Expr(:error, "invalid function name `true`")

    false(x)=body
    @Expr(:error, "invalid function name `false`")
end

ln = LineNumberNode(@__LINE__()+3, Symbol(@__FILE__))
@testset_desugar "@generated function" begin
    function f(x)
        body1(x)
        if $(Expr(:generated))
            gen_body1(x)
        else
            normal_body1(x)
        end
        body2
        if $(Expr(:generated))
            gen_body2
        else
            normal_body2
        end
    end
    begin
        begin
            global gsym1
            begin
                @Expr(:method, gsym1)
                @Expr(:method, gsym1,
                      Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any, Core.Any), Core.svec()),
                      @Expr(:lambda, [_self_, gsym2, x], [],
                            @Expr(:scope_block,
                                  begin
                                      @Expr(:meta, nospecialize, gsym2, x)
                                      Core._expr(:block,
                                                 $(QuoteNode(LineNumberNode(ln.line, ln.file))),
                                                 @Expr(:copyast, $(QuoteNode(:(body1(x))))),
                                                 # FIXME: These line numbers seem buggy?
                                                 $(QuoteNode(LineNumberNode(ln.line+1, ln.file))),
                                                 gen_body1(x),
                                                 $(QuoteNode(LineNumberNode(ln.line+6, ln.file))),
                                                 :body2,
                                                 $(QuoteNode(LineNumberNode(ln.line+7, ln.file))),
                                                 gen_body2)
                                  end)))
                maybe_unused(gsym1)
            end
        end
        @Expr(:method, f)
        @Expr(:method, f,
              Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec()),
              @Expr(:lambda, [_self_, x], [],
                    @Expr(:scope_block,
                          begin
                              @Expr(:meta, generated,
                                    @Expr(:new,
                                          Core.GeneratedFunctionStub,
                                          gsym1, $([:_self_, :x]),
                                          nothing,
                                          $(ln.line),
                                          $(QuoteNode(ln.file)),
                                          false))
                              body1(x)
                              normal_body1(x)
                              body2
                              normal_body2
                          end)))
        maybe_unused(f)
    end
end

@testset_desugar "macro" begin
    macro foo
    end
    @Expr(:method, $(Symbol("@foo")))

    macro foo(ex)
        body(ex)
    end
    begin
        @Expr(:method, $(Symbol("@foo")))
        @Expr(:method, $(Symbol("@foo")),
              Core.svec(Core.svec(Core.Typeof($(Symbol("@foo"))), Core.LineNumberNode, Core.Module, Core.Any), Core.svec()),
              @Expr(:lambda, [_self_, __source__, __module__, ex], [],
                    @Expr(:scope_block,
                          begin
                              @Expr(:meta, nospecialize, ex)
                              body(ex)
                          end)))
        maybe_unused($(Symbol("@foo")))
    end

    macro foo(ex; x=a)
        body(ex)
    end
    @Expr(:error, "macros cannot accept keyword arguments")

    macro ()
    end
    @Expr(:error, "invalid macro definition")
end

@testset "Forms without desugaring" begin
    # (expand-forms)
    # The following Expr heads are currently not touched by desugaring
    for head in [:quote, :top, :core, :globalref, :outerref, :module, :toplevel, :null, :meta, :using, :import, :export]
        ex = Expr(head, Expr(:foobar, :junk, nothing, 42))
        @test _expand_forms(ex) == ex
    end
    # flisp: inert,line have special representations on the julia side
    @test _expand_forms(QuoteNode(Expr(:$, :x))) == QuoteNode(Expr(:$, :x)) # flisp: `(inert ,expr)
    @test _expand_forms(LineNumberNode(1, :foo)) == LineNumberNode(1, :foo) # flisp: `(line ,line ,file)
end

end

#-------------------------------------------------------------------------------
# Julia AST Notes
#
# Broadly speaking there's three categories of `Expr` expression heads:
#   * Forms which represent normal julia surface syntax
#   * Special forms which are emitted by macros in the public API, but which
#     have no normal syntax.
#   * Forms which are used internally as part of lowering

# Here's the forms which are transformed as part of the desugaring pass in
# expand-table:
#
# function             expand-function-def
# ->                   expand-arrow
# let                  expand-let
# macro                expand-macro-def
# struct               expand-struct-def
# try                  expand-try
# lambda               expand-table
# block                expand-table
# .                    expand-fuse-broadcast
# .=                   expand-fuse-broadcast
# <:                   expand-table
# >:                   expand-table
# where                expand-wheres
# const                expand-const-decl
# local                expand-local-or-global-decl
# global               expand-local-or-global-decl
# local_def            expand-local-or-global-decl
# =                    expand-table
# abstract             expand-table
# primitive            expand-table
# comparison           expand-compare-chain
# ref                  partially-expand-ref
# curly                expand-table
# call                 expand-table
# do                   expand-table
# tuple                lower-named-tuple
# braces               expand-table
# bracescat            expand-table
# string               expand-table
# ::                   expand-table
# while                expand-table
# break                expand-table
# continue             expand-table
# for                  expand-for
# &&                   expand-and
# ||                   expand-or
# += -= *= .*= /= ./=  lower-update-op
# //= .//= \\= .\\=
# .+= .-= ^= .^= ÷=
# .÷= %= .%= |= .|=
# &= .&= $= ⊻= .⊻=
# <<= .<<= >>= .>>=
# >>>= .>>>=
# ...                  expand-table
# $                    expand-table
# vect                 expand-table
# hcat                 expand-table
# vcat                 expand-table
# typed_hcat           expand-table
# typed_vcat           expand-table
# '                    expand-table
# generator            expand-generator
# flatten              expand-generator
# comprehension        expand-table
# typed_comprehension  lower-comprehension

# Heads of internal AST forms (incomplete)
#
# Emitted by public macros:
#   inbounds                 @inbounds
#   boundscheck              @boundscheck
#   isdefined                @isdefined
#   generated                @generated
#   locals                   Base.@locals
#   meta                     @inline, @noinline, ...
#   symbolicgoto             @goto
#   symboliclabel            @label
#   gc_preserve_begin        GC.@preserve
#   gc_preserve_end          GC.@preserve
#   foreigncall              ccall
#   loopinfo                 @simd
#
# Scoping and variables:
#   scope_block
#   toplevel_butfirst
#   toplevel
#   aliasscope
#   popaliasscope
#   require_existing_local
#   local_def
#   const_if_global
#   top
#   core
#   globalref
#   outerref
#
# Looping:
#   _while
#   _do_while
#   break_block
#
# Types:
#   new
#   splatnew
#
# Functions:
#   lambda
#   method
#   ret_type
#
# Errors:
#   error
#   incomplete
#
# Other (TODO)
#   with_static_parameters

# IR:
#
# Exceptions:
#   enter
#   leave
#   pop_exception
#   gotoifnot
#
# SSAIR:
#   throw_undef_if_not
#   unreachable
#   undefcheck
#   invoke

