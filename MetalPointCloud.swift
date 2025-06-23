import Foundation
import SwiftUI
import MetalKit
import Metal

final class CoordinatorPointCloud: MTKCoordinator {
    var arData: ARProvider
    var depthState: MTLDepthStencilState!
    @Binding var confSelection: Int
    @Binding var scaleMovement: Float
    var flashActive: Bool = false // <-- Add this

    init(arData: ARProvider, confSelection: Binding<Int>, scaleMovement: Binding<Float>) {
        self.arData = arData
        self._confSelection = confSelection
        self._scaleMovement = scaleMovement
        super.init(content: arData.depthContent)
    }

    func setFlash(_ flash: Bool) {
        self.flashActive = flash
    }

    override func prepareFunctions() {
        guard let metalDevice = mtkView.device else { fatalError("Expected a Metal device.") }
        do {
            let library = EnvironmentVariables.shared.metalLibrary
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "pointCloudVertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "pointCloudFragmentShader")
            pipelineDescriptor.vertexDescriptor = createPlaneMetalVertexDescriptor()
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .less
            depthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor)
        } catch {
            print("Unexpected error: \(error).")
        }
    }

    override func draw(in view: MTKView) {
        content = arData.depthContent
        let confidence = (arData.isToUpsampleDepth) ? arData.upscaledConfidence : arData.confidenceContent
        guard arData.lastArData != nil else { return }
        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else { return }
        guard let passDescriptor = view.currentRenderPassDescriptor else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.setDepthStencilState(depthState)
        encoder.setVertexTexture(content.texture, index: 0)
        encoder.setVertexTexture(confidence.texture, index: 1)
        encoder.setVertexTexture(arData.colorYContent.texture, index: 2)
        encoder.setVertexTexture(arData.colorCbCrContent.texture, index: 3)

        var flashFlag = flashActive ? UInt32(1) : UInt32(0)
        encoder.setFragmentBytes(&flashFlag, length: MemoryLayout<UInt32>.stride, index: 0) // buffer(0) in shader

        var cameraIntrinsics = arData.lastArData!.cameraIntrinsics
        let depthResolution = simd_float2(x: Float(content.texture!.width), y: Float(content.texture!.height))
        let scaleRes = simd_float2(x: Float(arData.lastArData!.cameraResolution.width) / depthResolution.x,
                                   y: Float(arData.lastArData!.cameraResolution.height) / depthResolution.y)
        cameraIntrinsics[0][0] /= scaleRes.x
        cameraIntrinsics[1][1] /= scaleRes.y
        cameraIntrinsics[2][0] /= scaleRes.x
        cameraIntrinsics[2][1] /= scaleRes.y
        var pmv = makePerspectiveMatrixProjection(fovyRadians: Float.pi / 2.0,
                                                  aspect: Float(view.frame.width) / Float(view.frame.height),
                                                  nearZ: 10.0, farZ: 8000.0)
        encoder.setVertexBytes(&pmv, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
        encoder.setVertexBytes(&cameraIntrinsics, length: MemoryLayout<matrix_float3x3>.stride, index: 1)
        encoder.setVertexBytes(&confSelection, length: MemoryLayout<Int>.stride, index: 2)
        encoder.setRenderPipelineState(pipelineState)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(depthResolution.x * depthResolution.y))
        encoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}

struct MetalPointCloud: UIViewRepresentable {
    var arData: ARProvider
    @Binding var confSelection: Int
    @Binding var scaleMovement: Float
    var flashActive: Bool

    func makeCoordinator() -> CoordinatorPointCloud {
        let c = CoordinatorPointCloud(arData: arData, confSelection: $confSelection, scaleMovement: $scaleMovement)
        c.setFlash(flashActive)
        return c
    }
    func makeUIView(context: UIViewRepresentableContext<MetalPointCloud>) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.backgroundColor = context.environment.colorScheme == .dark ? .black : .white
        context.coordinator.setupView(mtkView: mtkView)
        return mtkView
    }
    func updateUIView(_ uiView: MTKView, context: UIViewRepresentableContext<MetalPointCloud>) {
        context.coordinator.setFlash(flashActive)
    }
}
