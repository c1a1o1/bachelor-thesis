# -*- coding: utf-8 -*-
# $File: get_roc_impl.pyx
# $Date: Mon Jun 01 22:42:20 2015 +0800
# $Author: jiakai <jia.kai66@gmail.com>

from nasmia.utils import serial
from nasmia.io import PointMatchResult

import numpy as np
cimport numpy as np

import os
import logging
logger = logging.getLogger(__name__)

cdef class ROCEvaluate:
    cdef object _args

    def __init__(self, args):
        self._args = args

    cdef _calc_single_test_image(self, flist, test_img_name):
        args = self._args

        border_dist_file = os.path.join(
            args.border_dir, test_img_name + '.nii.gz')
        logger.info('use border dist: {}'.format(border_dist_file))
        border_dist_np = serial.load(border_dist_file, np.ndarray)

        cdef int ref_dist = -1

        match_idx = []
        match_dist = []

        for i in flist:
            logger.info('load {}'.format(i))
            match = serial.load(i, PointMatchResult)
            assert match.img_shape == border_dist_np.shape
            match_idx.extend(match.idx)
            match_dist.extend(match.dist)
            if ref_dist == -1:
                ref_dist = match.args.ref_dist
            else:
                assert ref_dist == match.args.ref_dist

        cdef np.ndarray[np.int32_t, ndim=3] border_dist = border_dist_np
        cdef np.ndarray[np.int32_t, ndim=3] used = np.zeros_like(
            border_dist, dtype=np.int32)

        cdef int geo_dist, is_tp
        cdef int min_geo_dist = args.dist_min, max_geo_dist = args.dist_max
        cdef unsigned ptnum, x, y, z, xg, yg, zg
        cdef unsigned grid_size = args.dedup_grid_size

        raw_data = []
        for ptnum in np.argsort(match_dist):
            x, y, z = match_idx[ptnum]
            xd = x - x % grid_size
            yd = y - y % grid_size
            zd = z - z % grid_size
            if used[xd, yd, zd]:
                continue
            used[xd, yd, zd] = 1
            geo_dist = border_dist[x, y, z] - ref_dist
            is_tp = geo_dist >= min_geo_dist and geo_dist <= max_geo_dist
            raw_data.append((is_tp, match_dist[ptnum]))

        return self._calc_roc(np.asarray(raw_data, np.float32), len(match_idx))

    cdef _calc_roc(self, np.ndarray[np.float32_t, ndim=2] raw_data,
                   float max_nr_tp):
        """:return: roc curve: [(top ratio, tp, thresh)]"""
        assert raw_data.shape[1] == 2
        raw_data = raw_data[raw_data[:, 1].argsort()]
        cdef np.ndarray[np.float32_t, ndim=1] uniq_dist = np.unique(
            raw_data[:, 1])

        cdef np.ndarray[np.float32_t, ndim=2] result = np.empty(
            (uniq_dist.size, 3), dtype='float32')
        cdef float thresh, nr_tp = 0
        cdef unsigned idx, idx_src = 0

        for idx in range(uniq_dist.size):
            thresh = uniq_dist[idx]
            while idx_src < raw_data.shape[0] and raw_data[idx_src, 1] <= thresh:
                nr_tp += raw_data[idx_src, 0]
                idx_src += 1

            result[idx] = (idx_src / max_nr_tp, nr_tp / idx_src, thresh)

        return result

    def __call__(self):
        """:return: [(is_tp, thresh, idx)]"""
        flist = sorted([(os.path.basename(i).split('.')[0].split('-'), i)
                        for i in self._args.match_result])

        all_roc = []
        for key in sorted(set(i[0][1] for i in flist)):
            sub_flist = [i[1] for i in flist if i[0][1] == key]
            all_roc.append(self._calc_single_test_image(sub_flist, key))

        return self._merge_roc(all_roc)

    def _merge_roc(self, all_roc):
        """:return: merged roc curve: [(top ratio, tp, thresh,
            top ratio std, tp std)]"""
        all_dist = []
        for i in all_roc:
            all_dist.extend(i[:, 2])

        all_dist.sort()
        cdef np.ndarray[np.float32_t, ndim=1] uniq_dist = np.unique(all_dist)
        if uniq_dist.size >= self._args.nr_point * 2:
            last = uniq_dist[-1]
            uniq_dist = uniq_dist[::uniq_dist.size / self._args.nr_point]
            uniq_dist[-1] = last

        roc_idx = [0] * len(all_roc)

        cdef np.ndarray[np.float32_t, ndim=2] cur_roc

        cdef float thresh
        cdef unsigned cur_idx

        rst_roc = []

        for thresh in uniq_dist:
            tot_ratio = []
            tot_tp = []
            for i in range(len(all_roc)):
                cur_roc = all_roc[i]
                cur_idx = roc_idx[i]
                while (cur_idx < cur_roc.shape[0] and
                       cur_roc[cur_idx, 2] <= thresh):
                    cur_idx += 1

                if cur_idx:
                    tot_ratio.append(cur_roc[cur_idx - 1, 0])
                    tot_tp.append(cur_roc[cur_idx - 1, 1])
                else:
                    tot_ratio.append(0)

            rst_roc.append((np.mean(tot_ratio), np.mean(tot_tp), thresh,
                            np.std(tot_ratio), np.std(tot_tp)))

        return np.array(rst_roc, dtype=np.float32)


def get_roc(args):
    """:return: np array (nr, 3), (point num, precision, dist thresh)"""
    return ROCEvaluate(args)()
