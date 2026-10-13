"""Build-time straight-line graph lowering and last-use scheduling.
No graph metadata or scheduler is shipped: the result is ordinary C++ calls.
Trace events are uses, so a value is never overwritten before its diagnostic dump.
"""


class Generator:
    def __init__(self, views):
        self.views = views
        self.ops = []

    def emit(self, op, *inputs, args=()):
        name = "v" + str(len(self.ops))
        self.ops.append(
            {
                "name": name,
                "op": op,
                "inputs": list(inputs),
                "args": list(map(str, args)),
            }
        )
        return name

    def ptr(self, node, role):
        key = node["weights"].get(role)
        return "nullptr" if key is None else f"weights.at({self.views[key]['offset']})"

    def call(self, node, x, path="recognizer"):
        k, a, m = node["type"], node["attrs"], node["children"]

        def call(name, value=x):
            return self.call(m[name], value, path + "." + name)

        def op(kind, *values, args=()):
            return self.emit(kind, *values, args=args)

        if k == "Conv2d":
            oc, ic, kh, kw = self.views[node["weights"]["weight"]]["shape"]
            assert a["dilation"] == 1
            z = op(
                "conv",
                x,
                args=(
                    self.ptr(node, "weight"),
                    self.ptr(node, "bias"),
                    oc,
                    ic,
                    kh,
                    kw,
                    *a["stride"],
                    *a["padding"],
                    a["groups"],
                ),
            )
        elif k == "ConvTranspose2d":
            ic, oc, kh, kw = self.views[node["weights"]["weight"]]["shape"]
            assert (
                (kh, kw) == (2, 2)
                and a["stride"] == [2, 2]
                and a["padding"] == [0, 0]
                and a["output_padding"] == [0, 0]
                and a["dilation"] == 1
                and a.get("groups", 1) == 1
            )
            z = op(
                "transpose2",
                x,
                args=(self.ptr(node, "weight"), self.ptr(node, "bias"), ic, oc),
            )
        elif k == "Linear":
            out, inp = self.views[node["weights"]["weight"]]["shape"]
            z = op(
                "linear",
                x,
                args=(self.ptr(node, "weight"), self.ptr(node, "bias"), inp, out),
            )
        elif k == "LayerNorm":
            z = op(
                "layer_norm",
                x,
                args=(
                    self.ptr(node, "weight"),
                    self.ptr(node, "bias"),
                    str(a["eps"]) + "f",
                ),
            )
        elif k in ("ReLU", "SiLU", "HardSigmoid", "GELU", "HardSigmoidClip"):
            if k == "GELU":
                assert a["_approx"] == "none"
            z = op("activate", x, args=("Activation::" + k,))
        elif k in ("AvgPool2d", "MaxPool2d"):
            assert all(p == [0, 0] for p in a["_padding"])
            z = op(
                "pool",
                x,
                args=(*a["_kernel_size"], *a["_stride"], str(k == "AvgPool2d").lower()),
            )
        elif k == "RecognitionModel":
            z = call("head", op("to_sequence", call("encoder", call("backbone"))))
        elif k == "CTCHead":
            assert not a["use_guide"] and set(m) == {"head"}
            z = call("head")
        elif k == "PPLCNetV4Rec":
            z = call("pool", call("encoder"))
        elif k in ("RecEncoder", "RecStage", "Stage"):
            z = call("convolution") if k == "RecEncoder" else x
            for i in range(a["_depth"]):
                z = call(f"blocks_{i}", z)
        elif k in (
            "Conv2DBN",
            "ConvBNAct",
            "ConvNorm",
            "ConvNormAct",
            "ConvTransposeNormAct",
        ):
            if a.get("dynamic_same_padding"):
                assert a["kernel_size"] == [2, 2] and a["stride"] == [1, 1]
                x = op("pad_bottom_right", x)
            z = call("conv", x)
            if "act" in m:
                z = call("act", z)
        elif k == "StemBlock":
            s = call("stem1")
            branch = call("stem2b", call("stem2a", s))
            pooled = call("pool", op("pad_bottom_right", s))
            z = call("stem4", call("stem3", op("concat_channels", pooled, branch)))
        elif k in ("LCNetV4RecBlock", "LCNetV4Block"):
            s = call("token_conv")
            if "token_squeeze_excitation" in m:
                s = call("token_squeeze_excitation", s)
            z = call("channel_conv2", call("channel_act", call("channel_conv1", s)))
            if a["has_residual"]:
                z = op("add", s, z)
        elif k in ("TokenSqueezeExcitation", "SELayer", "SEModule"):
            gate = call(
                "hardsigmoid",
                call("conv2", call("relu", call("conv1", op("spatial_mean", x)))),
            )
            z = op("channel_multiply", x, gate)
        elif k == "EncoderWithLightSVTR":
            skip = call("act", call("skip_conv"))
            s = call("act", call("conv_reduce"))
            s = op("add", s, call("act", call("local_conv", s)))
            shape = op("shape", s)
            s = op("to_sequence", s)
            for i in range(a["_depth"]):
                s = call(f"svtr_block_{i}", s)
            z = op("add", op("from_sequence", call("norm", s), shape), skip)
        elif k == "SVTRBlock":
            s = op("add", x, call("self_attn", call("norm1")))
            z = op("add", s, call("mlp", call("norm2", s)))
        elif k == "SVTRMlp":
            z = call("fc2", call("act", call("fc1")))
        elif k == "MultiHeadAttention":
            q = call("query_proj")
            key = call("key_proj")
            v = call("value_proj")
            z = call("out_proj", op("attention", q, key, v, args=(a["num_heads"],)))
        elif k == "DetectionModel":
            z = call("head", call("neck", call("backbone")))
        elif k == "PPLCNetV4Det":
            z = call("encoder")
        elif k == "Encoder":
            value = call("convolution")
            z = []
            for i in range(a["_depth"]):
                value = call(f"blocks_{i}", value)
                z.append(value)
        elif k == "RSELayer":
            value = call("in_conv")
            z = call("squeeze_excitation_block", value)
            if a["shortcut"]:
                z = op("add", value, z)
        elif k == "RepLKInputConv":
            value = call("pw", call("conv"))
            z = op("add", value, call("squeeze_excitation_module", value))
        elif k == "RepLKFPN":
            features = [call(f"insert_conv_{i}", value) for i, value in enumerate(x)]
            in2, in3, in4, in5 = features
            out4 = op("add", in4, op("upsample", in5, args=(2,)))
            out3 = op("add", in3, op("upsample", out4, args=(2,)))
            out2 = op("add", in2, op("upsample", out3, args=(2,)))
            pyramid = [
                call(f"input_conv_{i}", value)
                for i, value in enumerate((out2, out3, out4, in5))
            ]
            parts = [
                op("upsample", pyramid[i], args=(2**i,)) if i else pyramid[i]
                for i in (3, 2, 1, 0)
            ]
            z = parts[0]
            for part in parts[1:]:
                z = op("concat_channels", z, part)
        elif k == "DBHead":
            z = op(
                "activate",
                call("conv_final", call("conv_up", call("conv_down"))),
                args=("Activation::Sigmoid",),
            )
        else:
            raise ValueError("Unsupported node: " + k)
        if isinstance(z, list):
            for i, value in enumerate(z):
                self.emit("trace", value, args=(path + "." + str(i),))
        else:
            self.emit("trace", z, args=(path,))
        return z

    def generate(self, tree, root="recognizer"):
        result = self.call(tree, "x", root)
        self.emit("return", result)
        last = {}
        types = {r["name"]: r["op"] for r in self.ops}
        for i, r in enumerate(self.ops):
            for v in r["inputs"]:
                last[v] = i
        lines = []
        reused = 0
        for i, r in enumerate(self.ops):
            op = r["op"]
            inputs = r["inputs"].copy()
            args = r["args"]
            name = r["name"]
            if op == "trace":
                lines.append(f'if(trace) trace->record("{args[0]}",{inputs[0]});')
            elif op == "shape":
                lines.append(f"const auto {name}={inputs[0]}.shape;")
            elif op == "return":
                lines.append(f"return {inputs[0]};")
            else:
                if (
                    op == "add"
                    and (inputs[0] == "x" or last[inputs[0]] != i)
                    and inputs[1] != "x"
                    and last[inputs[1]] == i
                ):
                    inputs.reverse()
                if (
                    op in ("activate", "add", "channel_multiply", "layer_norm")
                    and inputs[0] != "x"
                    and inputs[0] not in inputs[1:]
                    and last[inputs[0]] == i
                ):
                    inputs[0] = "std::move(" + inputs[0] + ")"
                    op += "_reuse"
                    reused += 1
                lines.append(f"auto {name}={op}(" + ",".join(inputs + args) + ");")
            if op != "return":
                for v in dict.fromkeys(r["inputs"]):
                    if v != "x" and last[v] == i and types[v] != "shape":
                        lines.append(f"{v}.release();")
        return "\n".join(lines), {
            "statements": len(self.ops),
            "inplace_operations": reused,
            "schedule": "static last-use releases; traced before overwrite",
        }
