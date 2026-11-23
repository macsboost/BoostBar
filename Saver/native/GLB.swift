import AppKit
import SceneKit
import simd

/// A small glTF 2.0 binary (.glb) loader for SceneKit, covering what BoostBar's models use: node hierarchies with
/// TRS / matrix transforms, triangle meshes with POSITION / NORMAL / TEXCOORD_0 / COLOR_0, 8/16/32-bit indices,
/// metallic-roughness materials with an optional embedded PNG base-colour texture, alpha blending, double-siding,
/// and node `extras` (kept by node name).
struct GLBModel {
    let root: SCNNode
    let extras: [String: [String: Any]]
}

enum GLBError: Error, CustomStringConvertible {
    case badFile(String)
    var description: String { switch self { case .badFile(let s): return s } }
}

enum GLB {
    static func load(_ url: URL) throws -> GLBModel {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(data.subdata(in: o..<o + 4).withUnsafeBytes { $0.load(as: UInt32.self) }) }
        guard data.count > 20, u32(0) == 0x4654_6C67 else { throw GLBError.badFile("\(url.lastPathComponent) is not a GLB") }
        let jsonLen = u32(12)
        let json = data.subdata(in: 20..<20 + jsonLen)
        var bin = Data()
        let binHeader = 20 + jsonLen
        if data.count >= binHeader + 8 {
            let binLen = u32(binHeader)
            bin = data.subdata(in: binHeader + 8..<binHeader + 8 + binLen)
        }
        guard let J = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw GLBError.badFile("bad JSON") }
        return try Builder(J: J, bin: bin).build()
    }
}

private struct Builder {
    let J: [String: Any]
    let bin: Data

    var accessors: [[String: Any]] { J["accessors"] as? [[String: Any]] ?? [] }
    var views: [[String: Any]] { J["bufferViews"] as? [[String: Any]] ?? [] }

    static let comps: [String: Int] = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16]

    /// Accessor values as floats (normalized integers scaled to 0…1).
    func floats(_ i: Int) -> (values: [Float], n: Int) {
        let a = accessors[i]
        let n = Self.comps[a["type"] as? String ?? "SCALAR"] ?? 1
        let count = a["count"] as? Int ?? 0
        let ct = a["componentType"] as? Int ?? 5126
        let normalized = a["normalized"] as? Bool ?? false
        guard let vi = a["bufferView"] as? Int else { return (Array(repeating: 0, count: count * n), n) }
        let v = views[vi]
        let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ct] ?? 4
        let base = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let stride = (v["byteStride"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? size * n
        var out = [Float](repeating: 0, count: count * n)
        bin.withUnsafeBytes { raw in
            for k in 0..<count {
                for c in 0..<n {
                    let o = base + k * stride + c * size
                    let f: Float
                    switch ct {
                    case 5126: f = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                    case 5121: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self)); f = normalized ? x / 255 : x
                    case 5123: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)); f = normalized ? x / 65535 : x
                    case 5125: f = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    case 5120: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int8.self)); f = normalized ? max(x / 127, -1) : x
                    case 5122: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self)); f = normalized ? max(x / 32767, -1) : x
                    default: f = 0
                    }
                    out[k * n + c] = f
                }
            }
        }
        return (out, n)
    }

    func indices(_ i: Int) -> [UInt32] {
        let a = accessors[i]
        let count = a["count"] as? Int ?? 0
        let ct = a["componentType"] as? Int ?? 5125
        guard let vi = a["bufferView"] as? Int else { return [] }
        let v = views[vi]
        let base = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        var out = [UInt32](repeating: 0, count: count)
        bin.withUnsafeBytes { raw in
            for k in 0..<count {
                switch ct {
                case 5121: out[k] = UInt32(raw.loadUnaligned(fromByteOffset: base + k, as: UInt8.self))
                case 5123: out[k] = UInt32(raw.loadUnaligned(fromByteOffset: base + k * 2, as: UInt16.self))
                default: out[k] = raw.loadUnaligned(fromByteOffset: base + k * 4, as: UInt32.self)
                }
            }
        }
        return out
    }

    func image(_ texIndex: Int) -> CGImage? {
        guard let textures = J["textures"] as? [[String: Any]], texIndex < textures.count,
              let src = textures[texIndex]["source"] as? Int,
              let images = J["images"] as? [[String: Any]], src < images.count,
              let vi = images[src]["bufferView"] as? Int else { return nil }
        let v = views[vi]
        let o = v["byteOffset"] as? Int ?? 0, len = v["byteLength"] as? Int ?? 0
        let d = bin.subdata(in: o..<o + len)
        guard let s = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

    func materials() -> [SCNMaterial] {
        (J["materials"] as? [[String: Any]] ?? []).map { m in
            let mat = SCNMaterial()
            mat.name = m["name"] as? String
            mat.lightingModel = .physicallyBased
            let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let f = (pbr["baseColorFactor"] as? [Double] ?? [1, 1, 1, 1]).map { CGFloat($0) }
            let color = CGColor(colorSpace: Self.linear, components: [f[0], f[1], f[2], 1])!
            if let t = pbr["baseColorTexture"] as? [String: Any], let ti = t["index"] as? Int, let img = image(ti) {
                mat.diffuse.contents = img
                mat.diffuse.wrapS = .repeat
                mat.diffuse.wrapT = .repeat
                mat.diffuse.mipFilter = .linear
                if f[0] < 0.999 || f[1] < 0.999 || f[2] < 0.999 { mat.multiply.contents = color }
            } else {
                mat.diffuse.contents = color
            }
            mat.metalness.contents = NSNumber(value: pbr["metallicFactor"] as? Double ?? 1)
            mat.roughness.contents = NSNumber(value: pbr["roughnessFactor"] as? Double ?? 1)
            mat.isDoubleSided = m["doubleSided"] as? Bool ?? false
            if (m["alphaMode"] as? String) == "BLEND" {
                mat.blendMode = .alpha
                mat.transparency = f.count > 3 ? f[3] : 1
                mat.writesToDepthBuffer = false
                mat.transparencyMode = .aOne
            }
            return mat
        }
    }

    func build() throws -> GLBModel {
        let mats = materials()
        let meshes = (J["meshes"] as? [[String: Any]] ?? []).map { mesh -> [SCNGeometry] in
            (mesh["primitives"] as? [[String: Any]] ?? []).compactMap { p -> SCNGeometry? in
                if let mode = p["mode"] as? Int, mode != 4 { return nil }
                guard let attrs = p["attributes"] as? [String: Int], let pi = attrs["POSITION"] else { return nil }
                var sources: [SCNGeometrySource] = []
                func src(_ acc: Int, _ sem: SCNGeometrySource.Semantic, want: Int? = nil) {
                    var (vals, n) = floats(acc)
                    if let want, want != n {               // e.g. RGB colours → RGBA
                        let count = vals.count / n
                        var o = [Float](repeating: 1, count: count * want)
                        for k in 0..<count { for c in 0..<min(n, want) { o[k * want + c] = vals[k * n + c] } }
                        vals = o; n = want
                    }
                    let d = vals.withUnsafeBufferPointer { Data(buffer: $0) }
                    sources.append(SCNGeometrySource(data: d, semantic: sem, vectorCount: vals.count / n, usesFloatComponents: true,
                                                     componentsPerVector: n, bytesPerComponent: 4, dataOffset: 0, dataStride: 4 * n))
                }
                src(pi, .vertex)
                if let ni = attrs["NORMAL"] { src(ni, .normal) }
                if let ti = attrs["TEXCOORD_0"] { src(ti, .texcoord) }
                if let ci = attrs["COLOR_0"] { src(ci, .color, want: 4) }
                let idx: [UInt32]
                if let ii = p["indices"] as? Int { idx = indices(ii) } else {
                    idx = (0..<UInt32(accessors[pi]["count"] as? Int ?? 0)).map { $0 }
                }
                let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                            primitiveCount: idx.count / 3, bytesPerIndex: 4)
                let g = SCNGeometry(sources: sources, elements: [el])
                if let mi = p["material"] as? Int, mi < mats.count { g.materials = [mats[mi]] }
                return g
            }
        }

        let nodeDefs = J["nodes"] as? [[String: Any]] ?? []
        var extras: [String: [String: Any]] = [:]
        var built: [SCNNode] = nodeDefs.enumerated().map { (i, n) in
            let node = SCNNode()
            node.name = n["name"] as? String ?? "node\(i)"
            if let m = n["matrix"] as? [Double], m.count == 16 {
                let f = m.map { Float($0) }
                node.simdTransform = simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                                             SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
            } else {
                if let t = n["translation"] as? [Double] { node.simdPosition = SIMD3(Float(t[0]), Float(t[1]), Float(t[2])) }
                if let r = n["rotation"] as? [Double] {
                    node.simdOrientation = simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3]))
                }
                if let s = n["scale"] as? [Double] { node.simdScale = SIMD3(Float(s[0]), Float(s[1]), Float(s[2])) }
            }
            if let e = n["extras"] as? [String: Any], let name = node.name { extras[name] = e }
            if let mi = n["mesh"] as? Int, mi < meshes.count {
                let gs = meshes[mi]
                if gs.count == 1 {
                    node.geometry = gs[0]
                } else {
                    for (k, g) in gs.enumerated() {
                        let c = SCNNode(geometry: g)
                        c.name = "\(node.name ?? "")_\(k)"
                        node.addChildNode(c)
                    }
                }
            }
            return node
        }
        for (i, n) in nodeDefs.enumerated() {
            for c in n["children"] as? [Int] ?? [] where c < built.count { built[i].addChildNode(built[c]) }
        }
        let root = SCNNode()
        root.name = "glb"
        let scenes = J["scenes"] as? [[String: Any]] ?? []
        let si = J["scene"] as? Int ?? 0
        let tops = scenes.isEmpty ? built.indices.filter { i in built[i].parent == nil } : (scenes[si]["nodes"] as? [Int] ?? [])
        for i in tops where i < built.count { root.addChildNode(built[i]) }
        built.removeAll()
        return GLBModel(root: root, extras: extras)
    }
}

extension SCNNode {
    /// Axis-aligned bounds of everything under this node, in this node's space.
    func deepBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        enumerateHierarchy { n, _ in
            guard n.geometry != nil else { return }
            let (a, b) = n.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = n.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: self)
                lo = simd_min(lo, p); hi = simd_max(hi, p); any = true
            } } }
        }
        return any ? (lo, hi) : nil
    }
}
