#include "cbow.h"
#include <stdio.h>
#include <assert.h>

__constant__ real expTable[EXP_TABLE_SIZE];

extern real *syn0;
extern int * table;
extern int vocab_size, layer1_size , layer1_size_aligned;
extern int negative , window;
extern int table_size;
// To batch data to minimize data transfer, sen stores words + alpha values
// alpha value start at offset = MAX_SENTENCE_NUM * MAX_SENTENCE_LENGTH

extern int * sen;



real * d_syn0 = NULL;
real * d_syn1neg = NULL;
int  * d_sen = NULL;
unsigned int * d_random = NULL;
int * d_table = NULL;

int maxThreadsPerBlock = 512;
int numBlock;
int shared_mem_usage;

void __global__ device_memset(real * array, int size){
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < size)
		array[idx] = 0;
}

__device__ void reduceInWarp( float * f, int idInWarp){
	for(int i = THREADS_PER_WORD /2; i > 0; i /= 2){
		if (idInWarp < i){
            f[idInWarp] += f[idInWarp + i];

        }
		 __syncthreads();
	}
}

void __global__ device_cbow(int sentence_num, int layer1_size, int layer1_size_aligned,
		int window, int negative, int table_size, int vocab_size,
		int * d_sen, int * d_table,
		float * d_syn0, float *d_syn1neg,
		unsigned int * d_random){


	int sentence_position = (threadIdx.x / THREADS_PER_WORD) + (blockDim.x / THREADS_PER_WORD) * blockIdx.x;
	int idInWarp = threadIdx.x % THREADS_PER_WORD;

	extern __shared__ float shared[];
	float * f = shared + (threadIdx.x / THREADS_PER_WORD) * THREADS_PER_WORD;
	float * neu1 = shared + BLOCK_SIZE + (threadIdx.x / THREADS_PER_WORD) * layer1_size_aligned;
	float * neu1e= shared + BLOCK_SIZE + (blockDim.x / THREADS_PER_WORD) * layer1_size_aligned + (threadIdx.x / THREADS_PER_WORD) * layer1_size_aligned;

	if (sentence_position < MAX_SENTENCE_LENGTH) {
		unsigned int next_random = d_random[sentence_position];

		for (int sentence_idx = 0; sentence_idx < sentence_num; sentence_idx++){

			for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD) neu1[c] = 0;
			for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD) neu1e[c] = 0;


			__syncthreads();
			next_random = next_random * (unsigned int) 1664525 + 1013904223;
			int b = next_random % window;
			int word = d_sen[sentence_idx * MAX_SENTENCE_LENGTH + sentence_position];
			// in -> hidden
			int cw = 0;
			for (int a = b; a < window * 2 + 1 - b; a++)
				if (a != window) {
					int w = sentence_position - window + a;
					if (w < 0)
						continue;
					if (w>= MAX_SENTENCE_LENGTH)
						continue;
					int last_word = d_sen[sentence_idx * MAX_SENTENCE_LENGTH + w];
					for (int c = idInWarp; c < layer1_size; c+= THREADS_PER_WORD)
						neu1[c] += d_syn0[c + last_word * layer1_size_aligned];

					cw++;
				}
			__syncthreads();
			if (cw) {
				for (int c = idInWarp; c < layer1_size; c+= THREADS_PER_WORD)
					neu1[c] /= cw;
				__syncthreads();
			// NEGATIVE SAMPLING
			int target, label;
			float alpha = (float) d_sen[MAX_SENTENCE_NUM * MAX_SENTENCE_LENGTH + sentence_idx];

			if (negative > 0)

				for (int d = 0; d < negative + 1; d++) {


					if (d == 0) {
						target = word;
						label = 1;
					} else {
						next_random = next_random * (unsigned int) 1664525
								+ 1013904223;
						target = d_table[(next_random) % table_size];
						if (target == 0)
							target = next_random % (vocab_size - 1) + 1;
						if (target == word)
							continue;
						label = 0;
					}
					int l2 = target * layer1_size_aligned;
					f[idInWarp] = 0;
					__syncthreads();
					//printf("%d %d: d=%d %f \n",blockIdx.x, threadIdx.x, d, f[idInWarp]);
					for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD){
						f[idInWarp] += neu1[c] * d_syn1neg[c + l2];
					    //printf("%d %d: d=%d %d %f %f %f\n",blockIdx.x, threadIdx.x, d, idInWarp,neu1[c], d_syn1neg[c+l2], neu1[c] * d_syn1neg[c + l2]);
				//	__syncthreads();
					}
					__syncthreads();
					// Do reduction here;
					reduceInWarp(f, idInWarp);
					//printf("%f\n",f[0]);
					float g;
					if (f[0] > MAX_EXP)
						g = (label - 1) * alpha;
					else if (f[0] < -MAX_EXP)
						g = (label - 0) * alpha;
					else
						g = (label - expTable[(int) ((f[0] + MAX_EXP)
									* (EXP_TABLE_SIZE / MAX_EXP / 2))]) * alpha;

					for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD)
						neu1e[c] += g * d_syn1neg[c + l2];
					for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD)
						d_syn1neg[c + l2] += g * neu1[c];
					__syncthreads();
				}
			// hidden -> in
			for (int a = b; a < window * 2 + 1 - b; a++)
				if (a != window) {
					int w = sentence_position - window + a;
					if (w < 0)
						continue;
					if (w >= MAX_SENTENCE_LENGTH)
						continue;
					int last_word = d_sen[sentence_idx * MAX_SENTENCE_LENGTH + w];

					for (int c = idInWarp; c < layer1_size; c+=THREADS_PER_WORD)
						d_syn0[c + last_word * layer1_size_aligned] += neu1e[c];

				}
			}
		}// End for sentence_idx
		// Update d_random
		if (idInWarp == 0 ) d_random[sentence_position] = next_random;
	}
}

#define cudaCheck(err) { \
	if (err != cudaSuccess) { \
		printf("CUDA error: %s: %s, line %d\n", cudaGetErrorString(err), __FILE__, __LINE__); \
		assert(err == cudaSuccess); \
	} \
}
void cleanUpGPU(){
	cudaCheck(cudaFree(d_syn1neg));
	cudaCheck(cudaFree(d_syn0));
	cudaCheck(cudaFreeHost(sen));
	cudaCheck(cudaFree(d_sen));
	cudaCheck(cudaFree(d_random));
	cudaCheck(cudaFree(d_table));
}
void initializeGPU(){
	// Device query
	int nDevices;
	cudaCheck(cudaGetDeviceCount(&nDevices));
	for (int i = 0; i < nDevices; i++) {
	    cudaDeviceProp prop;
	    cudaCheck(cudaGetDeviceProperties(&prop, i));
	    printf("Device Number: %d\n", i);
	    printf("  Device name: %s\n", prop.name);
	    printf("  Memory Clock Rate (KHz): %d\n",
	           prop.memoryClockRate);
	    printf("  Memory Bus Width (bits): %d\n",
	           prop.memoryBusWidth);
	    printf("  Peak Memory Bandwidth (GB/s): %f\n\n",
	           2.0*prop.memoryClockRate*(prop.memoryBusWidth/8)/1.0e6);
	}
	int device = 0;
	cudaCheck(cudaSetDevice(device));
	cudaDeviceProp prop;
	cudaCheck(cudaGetDeviceProperties(&prop, device));
	maxThreadsPerBlock = prop.maxThreadsPerBlock;
#if defined(DEBUG)
	printf(" Max Threads Per Block %d\n", maxThreadsPerBlock);
#endif

	real * h_expTable = (real *)malloc((EXP_TABLE_SIZE ) * sizeof(real));
	for (int i = 0; i < EXP_TABLE_SIZE; i++) {
		h_expTable[i] = exp((i / (real)EXP_TABLE_SIZE * 2 - 1) * MAX_EXP);
		h_expTable[i] = h_expTable[i] / (h_expTable[i] + 1);
	}
	cudaCheck(cudaMemcpyToSymbol(expTable, h_expTable, sizeof(real) * EXP_TABLE_SIZE));
	free(h_expTable);

	if (negative>0) {
		int syn1neg_size = vocab_size * layer1_size_aligned;
		cudaCheck(cudaMalloc((void**) & d_syn1neg, syn1neg_size * sizeof(real)));
		// call memset kernel
		device_memset<<<syn1neg_size / maxThreadsPerBlock + 1, maxThreadsPerBlock>>>(d_syn1neg, syn1neg_size );
		cudaCheck(cudaGetLastError());
		cudaCheck(cudaDeviceSynchronize());

	}

	int syn0_size = vocab_size * layer1_size_aligned;
	cudaCheck(cudaMalloc((void**) & d_syn0, syn0_size * sizeof(real)));
	cudaCheck(cudaMemcpy(d_syn0, syn0, syn0_size * sizeof(real), cudaMemcpyHostToDevice));

	cudaCheck(cudaMallocHost((void**)&sen, (MAX_SENTENCE_NUM * MAX_SENTENCE_LENGTH + MAX_SENTENCE_NUM) * sizeof(int) ));
	cudaCheck(cudaMalloc((void**)& d_sen, (MAX_SENTENCE_NUM * MAX_SENTENCE_LENGTH + MAX_SENTENCE_NUM) * sizeof(int) ));

	cudaCheck(cudaMalloc((void**) & d_random, MAX_SENTENCE_LENGTH * sizeof(unsigned int)));
	int h_random[MAX_SENTENCE_LENGTH];
	for (int i = 0 ; i < MAX_SENTENCE_LENGTH; i++) h_random[i] = (unsigned int) rand();
	cudaCheck(cudaMemcpy(d_random, h_random, MAX_SENTENCE_LENGTH * sizeof(unsigned int), cudaMemcpyHostToDevice));

	cudaCheck(cudaMalloc((void**) & d_table, table_size * sizeof(int)));
	cudaMemcpy(d_table, table, table_size * sizeof(int), cudaMemcpyHostToDevice);

	numBlock = MAX_SENTENCE_LENGTH / (BLOCK_SIZE/THREADS_PER_WORD) + 1;
	shared_mem_usage = (BLOCK_SIZE + (BLOCK_SIZE/THREADS_PER_WORD) * layer1_size_aligned * 2) * sizeof(real);

}

void TransferDataToGPU(){
	cudaCheck(cudaMemcpy( d_sen, sen,
				(MAX_SENTENCE_NUM * MAX_SENTENCE_LENGTH + MAX_SENTENCE_NUM) * sizeof(int) , cudaMemcpyHostToDevice));
}

void GetResultData(){
	cudaCheck(cudaMemcpy(syn0, d_syn0, vocab_size * layer1_size_aligned * sizeof(real), cudaMemcpyDeviceToHost));

}

void TrainGPU(int sentence_num) {
	TransferDataToGPU();

	device_cbow<<<numBlock,BLOCK_SIZE, shared_mem_usage >>>(sentence_num, layer1_size, layer1_size_aligned, window,
			 negative, table_size,  vocab_size,	 d_sen, d_table, d_syn0, d_syn1neg, d_random);

#if defined(DEBUG)
	cudaCheck(cudaGetLastError());
	cudaCheck(cudaDeviceSynchronize());
#endif

}

