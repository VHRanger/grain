/**
   A module for a variable used as a node in autograd computation graph

   TODO:
   - support shape ops
 */
module grain.autograd;

import std.traits : isArray, isBasicType;
import std.typecons : RefCounted, RefCountedAutoInitialize;
import mir.ndslice : isSlice;
import std.range : ElementType;

import grain.cuda;
import grain.utility : castArray;

/// CPU storage (i.e., GC dynamic array)
alias HostStorage(T) = T[];

/// fill CPU array with zero
auto zero_(T)(T[] s) { // if (!isBasicType!T) {
    import std.algorithm.mutation : fill;
    fill(s, 0);
    return s;
}

/// create new CPU array filled with zero
auto zeros(T)(size_t n) if (isArray!T) {
    auto s = new ElementType!T[n];
    return s.zero_();
}

///
unittest {
    float[] h = [1f, 2f, 3f];
    h.zero_();
    assert(h == [0f, 0f, 0f]);
    assert(zeros!(HostStorage!float)(3) == [0f, 0f, 0f]);
}


/// create new variable with uninitialized array and the same shape/strides to v on CPU
auto uninit(T, size_t dim)(Variable!(T, dim, HostStorage) v) {
    RefCounted!(T[]) data = new T[v.length];
    return Variable!(T, dim, HostStorage)(v.requiresGrad, v.shape, v.strides, data);
}

/// create new variable with uninitialized array of shape on CPU/CUDA
auto uninitVariable(T, alias S = HostStorage, size_t dim)(uint[dim] shape, bool requiresGrad = false) {
    import std.algorithm :reduce;
    const length = shape.reduce!"a * b";
    static if (is(S!T == HostStorage!T)) {
        RefCounted!(T[]) data = new T[length];
    }
    version(grain_cuda) {
        static if (is(S!T == DeviceStorage!T)) {
            RefCounted!(CuPtr!T) data = CuPtr!T(length);
        }
    }
    int[dim] strides;
    foreach (i; 0 .. dim-1) {
        assert(shape[i+1] < int.max);
        strides[i] = cast(int) shape[i+1];
    }
    strides[dim-1] = 1;
    return Variable!(T, dim, S)(requiresGrad, shape, strides, data);
}


version(grain_cuda) {
    /// create new variable with uninitialized array and the same shape/strides to v on CUDA
    auto uninit(T, size_t dim)(Variable!(T, dim, DeviceStorage) v) {
        return uninitVariable!(T, DeviceStorage, dim)(v.shape, v.requiresGrad);
    }


    alias DeviceStorage(T) = CuPtr!T;

    // enum bool isDevice(T) = isDeviceMemory(typeof(T.data)); // is(typeof({T.init.toHost();}));
    alias isDevice = isDeviceMemory;


    /// CUDA -> CPU memory conversion
    auto to(alias S : DeviceStorage, T)(T[] src) {
        import std.array : empty;
        return src.empty ? DeviceStorage!T() : DeviceStorage!T(src);
    }

    /// CPU -> CUDA memory conversion
    auto to(alias S : HostStorage, Src)(Src src) if (isDevice!Src) {
        return src.toHost();
    }

    ///
    unittest {
        auto h = [[0.1f, 0.2f, 0.3f], [0.4f, 0.5f, 0.6f]].variable;
        auto d = h.to!DeviceStorage;
        assert(h.data == d.to!HostStorage.data);
    }
}


/// type-erased variable used in BackProp object
struct UntypedVariable {
    import std.variant;
    bool requiresGrad;
    size_t dim;
    // size_t[]
    uint[] shape;
    // ptrdiff_t[]
    int[] strides;
    TypeInfo elem;
    Variant data, grad;
    size_t outPosition = 0;
    // RefCounted!
    BackProp bprop;

    this(T, size_t dim, alias Storage)(Variable!(T, dim, Storage) v) {
        this.elem = typeid(T);
        this.requiresGrad = v.requiresGrad;
        this.shape = v.shape.dup;
        this.strides = v.strides.dup;
        this.dim = dim;
        this.data = v.data;
        this.grad = v.grad;
    }

    auto get(T)() {
        return this.data.get!(RefCounted!T);
    }

    auto to(V : Variable!(T, dim, Storage), T, size_t dim, alias Storage)() {
        auto d = this.data.get!(RefCounted!(Storage!T));
        return Variable!(T, dim, Storage)(
            this.requiresGrad, this.shape[0..dim], this.strides[0..dim], d);
    }

    string toString() const {
        import std.format : format;
        return "UntypedVariable(%s, dim=%d, data=%s, shape=%s, strides=%s)".format(
            elem, dim, data, shape, strides);
    }

    auto gradSlice(V)() if (isVariable!V && isHost!V) {
        import mir.ndslice.slice : sliced;
        return grad.get!(typeof(V.init.data)).ptr.sliced(this.shape[0 .. Ndim!V].castArray!size_t);
    }
}

auto gradSlice(V)(V v) if (isVariable!V && isHost!V) {
    import mir.ndslice.slice : sliced;
    return v.grad.ptr.sliced(v.shape.castArray!size_t);
}



/// FIXME maybe singleton?
shared bool backprop = false;

/// stores information for backpropagation
struct BackProp {
    alias Proc = void delegate(UntypedVariable[], UntypedVariable[]);
    Proc proc;
    UntypedVariable[] inputs;
    UntypedVariable[] gradOutputs;
    size_t nGrad = 0;

    void backward(UntypedVariable* grad=null, size_t pos=0) {
        import std.exception : enforce;
        import std.range : empty;
        // enforce(!this.inputs.empty, "nothing to backprop");
        if (this.inputs.empty) return;
        ++this.nGrad;
        if (grad is null) {
            enforce(this.gradOutputs.length == 1, "this variable is not loss");
        } else {
            this.gradOutputs[pos] = *grad; // FIXME??
        }
        if (grad is null || this.nGrad == this.gradOutputs.length) {
            proc(this.gradOutputs, this.inputs);
        }

        // FIXME: reconsider this maybe
        // import core.memory : GC;
        // destroy(gradOutputs);
        // GC.free(&gradOutputs);
        // destroy(this);
        // GC.free(&this);
    }
}

///
unittest {
    import std.stdio;
    UntypedVariable u;
    {
        auto v = [[0f, 1f], [2f, 3f]].variable;
        u = UntypedVariable(v);
    }
    assert(u.get!(HostStorage!float) == [0, 1, 2, 3]);
}

/**
   A variable has autograd ability with mir.ndslice.Slice like data

   TODO: add SliceKind
*/
struct Variable(T, size_t dim, alias Storage = HostStorage) {
    bool requiresGrad = true;
    // size_t[dim]
    uint[dim] shape;
    // ptrdiff_t[dim]
    int[dim] strides;
    RefCounted!(Storage!T) data;
    RefCounted!(Storage!T) grad;
    // RefCounted!
    BackProp bprop;
    enum isHost = is(Storage!T == HostStorage!T);
    uint offset = 0;

    this(bool requiresGrad, uint[dim] shape, int[dim] strides, RefCounted!(Storage!T) data) {
        this.requiresGrad = requiresGrad;
        this.shape = shape;
        this.strides = strides;
        this.data = data;
        // this.grad.isHost = is(Storage!T == HostStorage!T);
        // if (this.requiresGrad) { // TODO enable this
            static if (is(Storage!T == HostStorage!T)) {
                this.grad = zeros!(Storage!T)(this.data.length);
            } else version (grain_cuda) {
                // TODO why is grain.cuda. required?
                this.grad = grain.cuda.zeros!(CuPtr!T)(this.data.length);
            }
        // }
    }

    @property
    auto ptr() {
        return this.data.ptr + offset;
    }

    @property
    bool defined() { return cast(size_t) data.ptr != 0; }

    auto dup() {
        static if (is(Storage!T == HostStorage!T)) {
            RefCounted!(Storage!T) d = new T[data.length];
            d[] = data[];
        } else {
            RefCounted!(Storage!T) d = data.dup;
        }
        auto y = Variable(this.requiresGrad, this.shape, this.strides, d);
        return y;
    }

    static if (is(Storage!T == HostStorage!T)) {
        auto sliced() {
            import mir.ndslice; // .slice : Slice, Universal;
            static if (dim == 0) {
                return [this.data[0]].sliced.universal;
            } else {
                return Slice!(Universal, [dim], T*)(
                    this.shape.castArray!size_t,
                    this.strides.castArray!ptrdiff_t, data.ptr);
            }
        }

        auto gradSliced() {
            import mir.ndslice; // .slice : Slice, Universal;
            static if (dim == 0) {
                return [this.grad[0]].sliced.universal;
            } else {
                return Slice!(Universal, [dim], T*)(
                    this.shape.castArray!size_t,
                    this.strides.castArray!ptrdiff_t, grad.ptr);
            }
        }
    }

    /// computes gradients of creator variables w.r.t. the arg grad
    void backward(UntypedVariable* grad, size_t pos=0) {
        this.bprop.backward(grad, pos);
    }

    /// computes gradients of creator variables w.r.t. this variable
    static if (dim == 0) void backward() {
        auto grad = UntypedVariable(1.0f.variable.to!Storage);
        this.bprop.backward(&grad, 0);
    }

    string toString() const {
        import std.format : format;
        return "Variable!(%s, dim=%d, %s)(data=%s, shape=%s, strides=%s)"
            .format(T.stringof, dim, Storage.stringof,
                    data, shape, strides);
    }
    /// TODO implement contiguous with mir.ndslice and cudnnTransformTensor

    auto opBinary(string op)(Variable!(T, dim, Storage) b) {
        import grain.chain : opBinaryFunc, reciprocal;
        static if (op == "+" || op == "*") {
            return opBinaryFunc!op(this, b);
        } else static if (op == "-") {
            return opBinaryFunc!"+"(this, b, 1, -1);
        } else static if (op == "/") {
            return opBinaryFunc!"*"(this, reciprocal(b));
        } else {
            static assert(false, "unsupported op: " ~ op);
        }
    }
}

/// test opBinary(string op)(Variable ...)
unittest {
    import mir.ndslice;
    import numir;
    import std.stdio;
    static foreach (op; ["+", "*", "-", "/"]) {
        {
            auto a = uniform!float(3, 2).slice.variable(true);
            auto b = uniform!float(3, 2).slice.variable(true);
            // this is equivalent to `a + b` if op == "+"
            auto c = a.opBinary!op(b);
            // this is equivalent to `a.sliced.slice + b.sliced.slice` if op == "+"
            auto e = a.sliced.slice.opBinary!op(b.sliced.slice);
            assert(approxEqual(c.sliced, e));

            auto gc = uniform!float(3, 2).slice.variable(true);
            auto ugc = UntypedVariable(gc);
            c.backward(&ugc);

            version (grain_cuda) {
                auto da = a.to!DeviceStorage;
                auto db = b.to!DeviceStorage;
                auto dc = da.opBinary!op(db);
                assert(approxEqual(dc.to!HostStorage.sliced, c.sliced));

                import grain.cuda : zero_;
                da.grad.zero_();
                db.grad.zero_();
                auto dugc = UntypedVariable(gc.to!DeviceStorage);
                dc.backward(&dugc);
                assert(approxEqual(da.to!HostStorage.gradSliced, a.gradSliced));
            }
        }
    }
}

/// test multiple addition
unittest {
    grain.autograd.backprop = true;
    auto x = [1f, 2f].variable(true);
    auto y = x + x; // x = 2 x
    auto z = y + y; // x = 4 x
    auto g = [0f, 1f].variable;
    auto u = UntypedVariable(g);
    z.backward(&u);
    assert(x.gradSliced == [0f, 4f]);
}

/// FIXME: test multiple addition with assign
// unittest {
//     grain.autograd.backprop = true;
//     auto x = [1f, 2f].variable(true);
//     x = x + x; // x = 2 x
//     x = x + x; // x = 4 x
//     auto g = [0f, 1f].variable;
//     auto u = UntypedVariable(g);
//     x.backward(&u);
//     x.gradSliced.writeln;
//     assert(x.gradSliced == [0f, 4f]);
// }



/// test Variable.defined
unittest {
    Variable!(float, 1, HostStorage) h;
    assert(!h.defined);
    assert(0.variable.defined);
    assert(0.1f.variable.defined);
    assert([0].variable.defined);
    assert([0.1f].variable.defined);

    version (grain_cuda) {
        Variable!(float, 1, DeviceStorage) d;
        assert(!d.defined);
        assert(!h.to!DeviceStorage.defined);
        assert(0.variable.to!DeviceStorage.defined);
        assert(0.1f.variable.to!DeviceStorage.defined);
        assert([0].variable.to!DeviceStorage.defined);
        assert([0.1f].variable.to!DeviceStorage.defined);
    }
}

/// a trait to identify variable object
enum bool isVariable(T) = is(T : Variable!(Elem, dim, Storage), Elem, size_t dim, alias Storage);

/// a trait to identify variable stored in CPU memory
enum bool isHost(V : Variable!(Elem, dim, Storage), Elem, size_t dim, alias Storage) = is(Storage!Elem == HostStorage!Elem);

/// a function to get the number of dimensions of variable
enum size_t Ndim(V : Variable!(Elem, dim, Storage), Elem, size_t dim, alias Storage) = dim;

/// an alias of element type (e.g., float, double and int) of variable
alias ElementType(V : Variable!(Elem, dim, Storage), Elem, size_t dim, alias Storage) = Elem;

/// total number of elements in variable
auto length(V)(V v) if (isVariable!V) {
    import std.algorithm : reduce;
    return v.shape.reduce!"a * b";
}

/// a helper function to create variable object from slice
auto variable(Sl)(Sl sl, bool requiresGrad = false) if (isSlice!Sl) {
    import mir.ndslice : universal, DeepElementType;
    import std.algorithm : reduce;
    import numir : Ndim;
    auto s = sl.universal;
    alias S = typeof(s);
    alias E = DeepElementType!S;
    auto size = s._lengths.reduce!"a * b";
    RefCounted!(E[]) data = s._iterator[0..size];
    uint[Ndim!S] shape;
    int[Ndim!S] strides;
    static foreach (i; 0 .. Ndim!S) {
        assert(s._lengths[i] < int.max);
        assert(s._strides[i] < int.max);
        shape[i] = cast(uint) s.length!i;
        strides[i] = cast(int) s._strides[i];
    }
    return Variable!(E, Ndim!S, HostStorage)(
        requiresGrad, shape, strides, data);
}

import std.traits : isNumeric;
/// a helper function to create variable object from CPU/CUDA array
auto variable(alias Storage=HostStorage, bool requiresGrad=false, T)(T x) if (isNumeric!T) {
    RefCounted!(T[]) data = [x];
    return Variable!(T, 0, Storage)(requiresGrad, [], [], data);
}

/// ditto
auto variable(A)(A a, bool requiresGrad=false) if (isArray!A) {
    import numir.core : nparray;
    return a.nparray.variable(requiresGrad);
}

///
version (grain_cuda) unittest {
    auto h = 0.5f.variable;
    auto d = h.to!DeviceStorage;
    assert(d.to!HostStorage.data == h.data);
}

/// copy variable into the other device (e.g., CPU -> CUDA or CUDA -> CPU)
Variable!(T, dim, Dst) to(alias Dst, T, size_t dim, alias Src)(Variable!(T, dim, Src) src) {
    static if (is(Dst!T == Src!T)) return src;
    else {
        import std.range :empty;
        RefCounted!(Dst!T) d = src.data.to!Dst;
        RefCounted!(Dst!T) g = src.grad.to!Dst;
        // FIXME: consider grad
        auto ret = typeof(return)(src.requiresGrad, src.shape, src.strides, d);
        ret.grad = g;
        return ret;
    }
}


///
unittest {
    import std.stdio;
    {
        // Variable!(float, 1) x;
        auto x = [-1f, -2f, -3f].variable;
        auto y = x.dup;
        x.data[0] = 1.0;
        static assert(isVariable!(typeof(x)));
        static assert(!isVariable!void);
        static assert(isHost!(typeof(x)));
        assert(y.data[0] == -1);
    }
    version (grain_cuda) {
        {
            auto x = [[1f, 3f],
                      [5f, 7f],
                      [9f, 11f]].variable;

            assert(x.data.length == 6);
            static assert(!isHost!(typeof(x.to!DeviceStorage)));
            auto xx = x.dup;
            assert(x.to!DeviceStorage.to!HostStorage.sliced == x.sliced);
        }
    }
}
