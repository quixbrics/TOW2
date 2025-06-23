/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that represents a point cloud.
*/

import Foundation
import SwiftUI
import MetalKit
import Metal

func makePerspectiveMatrixProjection(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let yProj: Float = 1.0 / tanf(fovyRadians * 0.5)
    let xProj: Float = yProj / aspect
    let zProj: Float = farZ / (farZ - nearZ)
    let proj: simd_float4x4 = simd_float4x4(SIMD4<Float>(xProj, 0, 0, 0),
                                           SIMD4<Float>(0, yProj, 0, 0),
                                           SIMD4<Float>(0, 0, zProj, 1.0),
                                           SIMD4<Float>(0, 0, -zProj * nearZ, 0))
    return proj
}
final class CoordinatorPointCloud: MTKCoordinator {
    var arData: ARProvider
    var depthState: MTLDepthStencilState!
    @Binding var confSelection: Int
    @Binding var scaleMovement: Float
    // Removed staticAngle and staticInc for static camera
    enum CameraModes {
        case quarterArc
        case sidewaysMovement
    }
    var currentCameraMode: CameraModes
    
    init(arData: ARProvider, confSelection: Binding<Int>, scaleMovement: Binding<Float>) {
        self.arData = arData
        self.currentCameraMode = .sidewaysMovement
        self._confSelection = confSelection
        self._scaleMovement = scaleMovement
        super.init(content: arData.depthContent)
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
    func calcCurrentPMVMatrix(viewSize: CGSize) -> matrix_float4x4 {
        let projection: matrix_float4x4 = makePerspectiveMatrixProjection(fovyRadians: Float.pi / 2.0,
                                                                          aspect: Float(viewSize.width) / Float(viewSize.height),
                                                                          nearZ: 10.0, farZ: 8000.0)
        var orientationOrig: simd_float4x4 = simd_float4x4()
        // Since the camera stream is rotated clockwise, rotate it back.
        orientationOrig.columns.0 = [0, -1, 0, 0]
        orientationOrig.columns.1 = [-1, 0, 0, 0]
        orientationOrig.columns.2 = [0, 0, 1, 0]
        orientationOrig.columns.3 = [0, 0, 0, 1]
        
        var translationOrig: simd_float4x4 = simd_float4x4()
        // Move the object forward to enhance visibility.
        translationOrig.columns.0 = [1, 0, 0, 0]
        translationOrig.columns.1 = [0, 1, 0, 0]
        translationOrig.columns.2 = [0, 0, 1, 0]
        translationOrig.columns.3 = [0, 0, +0, 1]
        
        // Set a fixed camera translation and rotation for a static view
        var translationCamera: simd_float4x4 = simd_float4x4()
        translationCamera.columns.0 = [1, 0, 0, 0]
        translationCamera.columns.1 = [0, 1, 0, 0]
        translationCamera.columns.2 = [0, 0, 1, 0]
        translationCamera.columns.3 = [0, 0, -1500 * scaleMovement, 1] // fixed position

        let cameraRotation = simd_quatf(angle: 0, axis: SIMD3(x: 0, y: 0, z: 0)) // no rotation

        let rotationMatrix: matrix_float4x4 = matrix_float4x4(cameraRotation)
        let pmv = projection * rotationMatrix * translationCamera * translationOrig * orientationOrig
        return pmv
    }
    override func draw(in view: MTKView) {
        content = arData.depthContent
        let confidence = (arData.isToUpsampleDepth) ? arData.upscaledConfidence:arData.confidenceContent
        guard arData.lastArData != nil else {
            print("Depth data not available; skipping a draw.")
            return
        }
        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else { return }
        guard let passDescriptor = view.currentRenderPassDescriptor else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.setDepthStencilState(depthState)
        encoder.setVertexTexture(content.texture, index: 0)
        encoder.setVertexTexture(confidence.texture, index: 1)
        encoder.setVertexTexture(arData.colorYContent.texture, index: 2)
        encoder.setVertexTexture(arData.colorCbCrContent.texture, index: 3)
        // Camera-intrinsics units are in full camera-resolution pixels.
        var cameraIntrinsics = arData.lastArData!.cameraIntrinsics
        let depthResolution = simd_float2(x: Float(content.texture!.width), y: Float(content.texture!.height))
        let scaleRes = simd_float2(x: Float( arData.lastArData!.cameraResolution.width) / depthResolution.x,
                                                y: Float(arData.lastArData!.cameraResolution.height) / depthResolution.y )
        cameraIntrinsics[0][0] /= scaleRes.x
        cameraIntrinsics[1][1] /= scaleRes.y

        cameraIntrinsics[2][0] /= scaleRes.x
        cameraIntrinsics[2][1] /= scaleRes.y
        var pmv = calcCurrentPMVMatrix(viewSize: CGSize(width: view.frame.width, height: view.frame.height))
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
    func makeCoordinator() -> CoordinatorPointCloud {
        return CoordinatorPointCloud(arData: arData, confSelection: $confSelection, scaleMovement: $scaleMovement)
    }
    func makeUIView(context: UIViewRepresentableContext<MetalPointCloud>) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.backgroundColor = context.environment.colorScheme == .dark ? .black : .white
        context.coordinator.setupView(mtkView: mtkView)
        return mtkView
    }
    
    // `UIViewRepresentable` requires this implementation; however, the sample
    // app doesn't use it. Instead, `MTKView.delegate` handles display updates.
    func updateUIView(_ uiView: MTKView, context: UIViewRepresentableContext<MetalPointCloud>) {
        
    }
}
