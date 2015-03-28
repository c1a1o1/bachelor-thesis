# -*- coding: utf-8 -*-
# $File: master.py
# $Date: Sat Mar 28 21:37:05 2015 +0800
# $Author: jiakai <jia.kai66@gmail.com>

from .common import ISAParam, SharedValue
from .worker import ISAWorker
from ..op import floatX

import numpy as np

from collections import OrderedDict
import multiprocessing
import logging
logger = logging.getLogger(__name__)

class ISA(object):
    _isa_param = None
    _shared_val = None
    _workers = None
    _nr_data = None

    def __init__(self, isa_param, data, nr_worker, gpu_list=None):
        """
        :param data: numpy matrix of shape (in_dim, nr_data)
        :param gpu_list: if not None, specify the gpus of each worker"""
        assert isinstance(isa_param, ISAParam)
        assert data.ndim == 2 and data.shape[0] == isa_param.in_dim

        self._isa_param = isa_param
        self._shared_val = SharedValue(isa_param)
        self._nr_data = data.shape[1]

        assert nr_worker > 0
        if gpu_list is None:
            gpu_list = [None] * nr_worker
        else:
            assert len(gpu_list) == nr_worker
        self._workers = []
        for i in range(nr_worker):
            start = i * data.shape[1] / nr_worker
            end = (i + 1) * data.shape[1] / nr_worker
            worker = ISAWorker(
                self._isa_param, self._shared_val,
                data[:, start:end], data.shape[1])
            worker.start_worker(gpu_list[i])
            self._workers.append(worker)

        self._init_whiten()
        self._init_weight()

    def perform_iter(self, learning_rate):
        """perform one iteration
        :return: monitor channels as OrderedDict"""
        acc = self._shared_val.result_accum
        w = self._shared_val.isa_weight

        monitor = OrderedDict()

        monitor['learning_rate'] = learning_rate

        # compute grad
        acc.reset()
        self._invoke_workers(lambda i: i.accum_grad())
        delta = acc.get()
        delta *= learning_rate
        monitor['RMS[delta]'] = float(np.sqrt(np.square(delta).mean()))

        # update weight
        w -= delta.reshape(w.shape)
        self._normalize_weight()

        # calc cost
        acc.reset()
        self._invoke_workers(lambda i: i.accum_cost())
        cost = acc.get()
        assert cost.size == 1
        monitor['cost'] = float(cost[0])

        return monitor

    def _init_whiten(self):
        acc = self._shared_val.result_accum

        # calc mean and sustract by mean
        logger.info('calc data mean')
        acc.reset()
        self._invoke_workers(lambda i: i.accum_data_sum())
        self._shared_val.data_mean[:] = acc.get() / self._nr_data
        self._invoke_workers(lambda i: i.sub_by_mean())

        # calc cov matrix
        logger.info('calc data cov')
        acc.reset()
        self._invoke_workers(lambda i: i.accum_data_cov())
        cov = acc.get().reshape(self._isa_param.in_dim, self._isa_param.in_dim)
        cov /= self._nr_data

        # eigen decomposition and get 
        eig_val, eig_vec = np.linalg.eigh(cov)
        idx = eig_val.argsort()[::-1]
        eig_val = eig_val[idx]
        eig_vec = eig_vec[:, idx]

        w = np.zeros_like(self._shared_val.data_whitening)
        thresh = np.square(eig_val).sum() * self._isa_param.pca_energy_keep
        idx = 0
        while thresh > 0 or idx < self._isa_param.hid_dim:
            cur_ev = eig_val[idx]
            assert cur_ev >= self._isa_param.min_eigen
            w[idx] = eig_vec[:, idx] / np.sqrt(cur_ev)
            thresh -= np.square(cur_ev)
            idx += 1
        if idx < w.shape[0]:
            w = w[:idx]
            self._shared_val.reset_in_dim(idx)
            self._invoke_workers(lambda i: i.reset_in_dim(idx))
            logger.info('reduce input dimension to {}'.format(idx))
        self._shared_val.data_whitening[:] = w
        self._invoke_workers(lambda i: i.mul_by_whiten())

    def _invoke_workers(self, func):
        hdl = []
        for i in self._workers:
            hdl.append(func(i))
        for i in hdl:
            i.wait()

    def _init_weight(self):
        rng = np.random.RandomState(19931102)
        w = self._shared_val.isa_weight
        w[:] = rng.uniform(size=w.shape)
        self._normalize_weight()

    def _normalize_weight(self):
        w = self._shared_val.isa_weight
        wwt = w.dot(w.T)
        eig_val, eig_vec = np.linalg.eigh(wwt)
        w[:] = eig_vec.dot(np.diag(1.0 / np.sqrt(eig_val))).dot(
            eig_vec.T).dot(w)

    def apply_to_data(self, data, do_reduce=True):
        assert data.ndim == 2 and data.shape[0] == self._isa_param.in_dim

        # whiten
        wht = data - self._shared_val.data_mean.reshape(-1, 1)
        wht = np.dot(self._shared_val.data_whitening, data)

        hidv = np.square(np.dot(self._shared_val.isa_weight, wht))
        if do_reduce:
            hidv_red = np.dot(self._isa_param.make_hidout_conn_mat(), hidv)
            return np.sqrt(hidv_red)
        return hidv