#ifndef ASTRARIUM_WORKERS_H
#define ASTRARIUM_WORKERS_H

#ifdef _WIN32
#include <windows.h>

typedef HANDLE WorkerThread;
typedef LPTHREAD_START_ROUTINE WorkerFunction;
#define WORKER_RETURN DWORD WINAPI
#define WORKER_DONE 0

static inline int worker_start(WorkerThread *thread, WorkerFunction function, void *data) {
	*thread = CreateThread(NULL, 0, function, data, 0, NULL);
	return *thread != NULL;
}

static inline void worker_join(WorkerThread thread) {
	WaitForSingleObject(thread, INFINITE);
	CloseHandle(thread);
}

static inline int worker_cores(void) {
	SYSTEM_INFO info;
	GetSystemInfo(&info);
	return info.dwNumberOfProcessors > 0 ? (int)info.dwNumberOfProcessors : 1;
}
#else
#include <pthread.h>
#include <unistd.h>

typedef pthread_t WorkerThread;
typedef void *(*WorkerFunction)(void *);
#define WORKER_RETURN void *
#define WORKER_DONE NULL

static inline int worker_start(WorkerThread *thread, WorkerFunction function, void *data) {
	return pthread_create(thread, NULL, function, data) == 0;
}

static inline void worker_join(WorkerThread thread) {
	pthread_join(thread, NULL);
}

static inline int worker_cores(void) {
	long count = sysconf(_SC_NPROCESSORS_ONLN);
	return count > 0 ? (int)count : 1;
}
#endif

#endif
