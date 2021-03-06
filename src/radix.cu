#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "naive.h"
#include "radix.h"

namespace StreamCompaction {
	namespace Radix {
		using StreamCompaction::Common::PerformanceTimer;
		PerformanceTimer& timer() {
			static PerformanceTimer timer;
			return timer;
		}

		int *dev_Data[2];
		int *dev_bArray;
		int *dev_eArray;
		int *dev_fArray;
		int *dev_tArray;
		int *dev_dArray;
		int *dev_materialIds;
		PathSegment *dev_temp_paths[2];
		ShadeableIntersection *dev_temp_intersections[2];

		__global__ void cudaSweepUp(int n, int d, int *data) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			int interval_length = 1 << (d + 1);
			if (index >= n)
				return;
			//int idx1 = index * interval_length + (1 << (d + 1)) - 1;
			//int idx2 = index * interval_length + (1 << d) - 1;
			data[index * interval_length + (1 << (d + 1)) - 1] += data[index * interval_length + (1 << d) - 1];
		}

		__global__ void cudaSweepDown(int n, int d, int *data) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			int interval_length = 1 << (d + 1);
			// k from 0 to n-1
			if (index >= n)
				return;

			int temp = data[index * interval_length + (1 << d) - 1];
			data[index * interval_length + (1 << d) - 1] = data[index * interval_length + (1 << (d + 1)) - 1];
			data[index * interval_length + (1 << (d + 1)) - 1] += temp;
		}

		__global__ void cudaGetBEArray(int pass, int *idata, int *odata1, int *odata2, int n) {
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n)
				return;
			odata1[index] = (idata[index] >> pass) & 1;
			odata2[index] = odata1[index] ^ 1;
		}

		__global__ void cudaGetTArray(int *idata, int *e, int *odata, int n) {
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			int totalFalses = idata[n - 1] + e[n - 1];
			if (index >= n)
				return;
			odata[index] = index - idata[index] + totalFalses;
		}

		__global__ void cudaGetDArray(int *idata1, int *idata2, int *idata3, int *odata, int n) {
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n)
				return;
			odata[index] = idata1[index] ? idata2[index] : idata3[index];
		}

		__global__ void cudaGetResult(int *idata, int *odata, int *data, int n) {
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n)
				return;
			odata[idata[index]] = data[index];
		}

		void RadixSort(int n, int *odata, int *idata) {

			int blockSize = 512;
			int blockNum;
			int celllog = ilog2ceil(n);
			int pow2len = 1 << celllog;
			int pout = 1;
			cudaMalloc((void**)&dev_Data[0], n * sizeof(int));
			cudaMalloc((void**)&dev_Data[1], n * sizeof(int));
			cudaMalloc((void**)&dev_bArray, n * sizeof(int));
			cudaMalloc((void**)&dev_eArray, pow2len * sizeof(int));
			cudaMalloc((void**)&dev_fArray, pow2len * sizeof(int));
			cudaMalloc((void**)&dev_tArray, n * sizeof(int));
			cudaMalloc((void**)&dev_dArray, n * sizeof(int));
			cudaMemset(dev_eArray, 0, pow2len * sizeof(int));
			cudaMemcpy(dev_Data[0], idata, sizeof(int) * n, cudaMemcpyHostToDevice);
			checkCUDAError("cudaMemcpy to device failed!");
			checkCUDAError("cudaMalloc failed!");

			int max_num = 0;
			for (int i = 0; i < n; i++)
				if (idata[i] > max_num)
					max_num = idata[i];

			timer().startGpuTimer();
			int pass = 0;
			while (true) {
				int pin = pout ^ 1;
				if ((max_num >> pass) == 0)
					break;
				blockNum = n / blockSize + 1;
				cudaGetBEArray << <blockNum, blockSize >> > (pass, dev_Data[pin], dev_bArray, dev_eArray, n);
				cudaMemcpy(dev_fArray, dev_eArray, pow2len * sizeof(int), cudaMemcpyDeviceToDevice);
				checkCUDAError("cudaMemcpy device to device failed!");

				for (int d = 0; d <= celllog - 1; d++) {
					int interval_length = (1 << (d + 1));
					blockNum = (pow2len / interval_length + blockSize) / blockSize;
					cudaSweepUp << <blockNum, blockSize >> > (pow2len / interval_length, d, dev_fArray);
				}

				cudaMemset(dev_fArray + pow2len - 1, 0, sizeof(int));
				checkCUDAError("cudaMemset failed!");
				for (int d = celllog - 1; d >= 0; d--) {
					int interval_length = (1 << (d + 1));
					blockNum = (pow2len / interval_length + blockSize) / blockSize;
					cudaSweepDown << <blockNum, blockSize >> > (pow2len / interval_length, d, dev_fArray);
				}

				blockNum = n / blockSize + 1;
				cudaGetTArray << <blockNum, blockSize >> > (dev_fArray, dev_eArray, dev_tArray, n);
				cudaGetDArray << <blockNum, blockSize >> > (dev_bArray, dev_tArray, dev_fArray, dev_dArray, n);
				cudaGetResult << <blockNum, blockSize >> > (dev_dArray, dev_Data[pout], dev_Data[pin], n);

				pass++;
				pout ^= 1;
			}
			timer().endGpuTimer();

			cudaMemcpy(odata, dev_Data[pout ^ 1], sizeof(int) * n, cudaMemcpyDeviceToHost);
			checkCUDAError("cudaMemcpy to host failed!");


			cudaFree(dev_Data[0]);
			cudaFree(dev_Data[1]);
			cudaFree(dev_bArray);
			cudaFree(dev_eArray);
			cudaFree(dev_fArray);
			cudaFree(dev_tArray);
			cudaFree(dev_dArray);
		}

		__global__ void kernStoreMaterialId(int n, int * dev_materialIds, ShadeableIntersection *dev_interactions) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			if (index >= n)
				return;
			dev_materialIds[index] = dev_interactions[index].materialId;
		}

		__global__ void cudaGetResult_Path_Interactions(int *idata, int *odata, int *data, int n, 
			PathSegment *odev_paths, ShadeableIntersection *odev_interactions,
			PathSegment *dev_paths, ShadeableIntersection *dev_interactions) {
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n)
				return;
			odata[idata[index]] = data[index];
			odev_paths[idata[index]] = dev_paths[index];
			odev_interactions[idata[index]] = dev_interactions[index];

		}
		__host__ __device__ int GetMax(int *idata, int n) {
			int max_num = 0;
			for (int i = 0; i < n; i++)
				if (idata[i] > max_num)
					max_num = idata[i];
			return max_num;

		}
		void RadixSort_Path_Interactions(int n, PathSegment *dev_paths, ShadeableIntersection *dev_interactions, int m_num) {
			
			int blockSize = 512;
			int blockNum;
			int celllog = ilog2ceil(n);
			int pow2len = 1 << celllog;
			int pout = 1;
			cudaMalloc((void**)&dev_temp_paths[0], n * sizeof(PathSegment));
			cudaMalloc((void**)&dev_temp_paths[1], n * sizeof(PathSegment));
			cudaMalloc((void**)&dev_temp_intersections[0], n * sizeof(ShadeableIntersection));
			cudaMalloc((void**)&dev_temp_intersections[1], n * sizeof(ShadeableIntersection));
			cudaMalloc((void**)&dev_Data[0], n * sizeof(int));
			cudaMalloc((void**)&dev_Data[1], n * sizeof(int));
			cudaMalloc((void**)&dev_bArray, n * sizeof(int));
			cudaMalloc((void**)&dev_eArray, pow2len * sizeof(int));
			cudaMalloc((void**)&dev_fArray, pow2len * sizeof(int));
			cudaMalloc((void**)&dev_tArray, n * sizeof(int));
			cudaMalloc((void**)&dev_dArray, n * sizeof(int));
			cudaMemset(dev_eArray, 0, pow2len * sizeof(int));
			checkCUDAError("cudaMemcpy to device failed!");
			checkCUDAError("cudaMalloc failed!");

			blockNum = (n + blockSize) / blockSize;
			kernStoreMaterialId<<<blockNum, blockSize>>>(n, dev_Data[0], dev_interactions);
			cudaMemcpy(dev_temp_paths[0], dev_paths, n * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
			cudaMemcpy(dev_temp_intersections[0], dev_interactions, n * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);

			int max_num = m_num - 1;

			timer().startGpuTimer();
			int pass = 0;
			while (true) {
				int pin = pout ^ 1;
				if ((max_num >> pass) == 0)
					break;
				blockNum = n / blockSize + 1;
				cudaGetBEArray << <blockNum, blockSize >> >(pass, dev_Data[pin], dev_bArray, dev_eArray, n);
				cudaMemcpy(dev_fArray, dev_eArray, pow2len * sizeof(int), cudaMemcpyDeviceToDevice);
				checkCUDAError("cudaMemcpy device to device failed!");

				for (int d = 0; d <= celllog - 1; d++) {
					int interval_length = (1 << (d + 1));
					blockNum = (pow2len / interval_length + blockSize) / blockSize;
					cudaSweepUp << <blockNum, blockSize >> >(pow2len / interval_length, d, dev_fArray);
				}

				cudaMemset(dev_fArray + pow2len - 1, 0, sizeof(int));
				checkCUDAError("cudaMemset failed!");
				for (int d = celllog - 1; d >= 0; d--) {
					int interval_length = (1 << (d + 1));
					blockNum = (pow2len / interval_length + blockSize) / blockSize;
					cudaSweepDown << <blockNum, blockSize >> >(pow2len / interval_length, d, dev_fArray);
				}

				blockNum = n / blockSize + 1;
				cudaGetTArray << <blockNum, blockSize >> > (dev_fArray, dev_eArray, dev_tArray, n);
				cudaGetDArray << <blockNum, blockSize >> >(dev_bArray, dev_tArray, dev_fArray, dev_dArray, n);
				cudaGetResult_Path_Interactions << <blockNum, blockSize >> >(dev_dArray, dev_Data[pout], dev_Data[pin], n, 
					dev_temp_paths[pout], dev_temp_intersections[pout],
					dev_temp_paths[pin], dev_temp_intersections[pin]);


				pass++;
				pout ^= 1;
			}
			timer().endGpuTimer();

			cudaMemcpy(dev_paths, dev_temp_paths[pout ^ 1], sizeof(PathSegment) * n, cudaMemcpyDeviceToDevice);
			cudaMemcpy(dev_interactions, dev_temp_intersections[pout ^ 1], sizeof(ShadeableIntersection) * n, cudaMemcpyDeviceToDevice);
			checkCUDAError("cudaMemcpy to host failed!");

			cudaFree(dev_temp_paths[0]);
			cudaFree(dev_temp_paths[1]);
			cudaFree(dev_temp_intersections[0]);
			cudaFree(dev_temp_intersections[1]);
			cudaFree(dev_Data[0]);
			cudaFree(dev_Data[1]);
			cudaFree(dev_bArray);
			cudaFree(dev_eArray);
			cudaFree(dev_fArray);
			cudaFree(dev_tArray);
			cudaFree(dev_dArray);
		}


	}
}