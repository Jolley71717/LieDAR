import Metal
import XCTest

/// Probe: can this machine (or simulator) give us a Metal device, compile a shader from a source
/// string, and read a depth texture back? It skips, and never fails, with the exact reason
/// "no Metal device" when there is none, so CI reports BLOCKED rather than red. The package's
/// tests do not depend on Metal; this tells us whether the preview path can.
final class MetalAvailabilityTests: XCTestCase {

    func testDeviceShaderAndDepthReadback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 liedar_probe_vertex(uint vid [[vertex_id]]) { return float4(0, 0, 0.25, 1); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "liedar_probe_vertex"), "runtime shader compilation")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let readback = try XCTUnwrap(device.makeBuffer(length: 4 * 4 * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())

        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0.75
        try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()

        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 4, height: 4, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: 16, destinationBytesPerImage: 64)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        let values = Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Float.self), count: 16))
        XCTAssertEqual(values, [Float](repeating: 0.75, count: 16), "depth readback on \(device.name)")
    }
}
